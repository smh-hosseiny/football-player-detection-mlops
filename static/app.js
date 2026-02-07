class PlayerDetectionApp {
  constructor() {
    this.apiConfig = {
      image: window.API_ENDPOINTS?.image || '/api/predict',
      video: window.API_ENDPOINTS?.video || '/api/predict_video',
      videoUpload: window.API_ENDPOINTS?.videoUpload || '/api/upload_video',
      wsBase: `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}`,
      timeout: 300000 // 5 min
    };

    this.state = {
      currentFile: null,
      isProcessing: false,
      videoController: null,
      mediaUrl: null,
      ws: null,
      sessionId: null,
      streamedDetections: [],
      videoMeta: null
    };

    this.initElements();
    this.bindEvents();
    this.validateEnvironment();
  }

  initElements() {
    this.uploadInput = document.getElementById('mediaUpload');
    this.canvas = document.getElementById('canvas');
    this.video = document.getElementById('video');
    this.ctx = this.canvas.getContext('2d');
    this.statusEl = document.getElementById('status');
    this.errorEl = document.getElementById('error-container');
    this.playBtn = document.getElementById('play');
    this.pauseBtn = document.getElementById('pause');
    this.stopBtn = document.getElementById('stop');
    this.clearBtn = document.getElementById('clear');
    this.progressSection = document.getElementById('progress-section');
    this.progressBar = document.getElementById('progress-bar');
    this.progressText = document.getElementById('progress-text');
    this.progressFrames = document.getElementById('progress-frames');
    this.progressEta = document.getElementById('progress-eta');
    this.videoOptions = document.getElementById('video-options');
    this.frameSkipInput = document.getElementById('frameSkip');
    this.frameSkipValue = document.getElementById('skip-value');
    this.confThresholdInput = document.getElementById('confThreshold');
    this.confThresholdValue = document.getElementById('conf-value');
  }

  bindEvents() {
    this.uploadInput.addEventListener('change', (e) => this.handleFileSelect(e));
    this.clearBtn.addEventListener('click', () => this.clearAll());
    this.playBtn.addEventListener('click', () => this.videoController?.play());
    this.pauseBtn.addEventListener('click', () => this.videoController?.pause());
    this.stopBtn.addEventListener('click', () => this.videoController?.stop());
    
    this.frameSkipInput.addEventListener('input', (e) => {
      this.frameSkipValue.textContent = e.target.value;
      // Send updated frame_skip to server if streaming
      if (this.state.ws && this.state.ws.readyState === WebSocket.OPEN) {
        this.state.ws.send(JSON.stringify({
          action: 'update_frame_skip',
          frame_skip: parseInt(e.target.value, 10),
        }));
      }
    });
    this.confThresholdInput.addEventListener('input', (e) => {
      this.confThresholdValue.textContent = e.target.value;
    });

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
      
      switch(e.code) {
        case 'Space': e.preventDefault(); this.videoController?.play(); break;
        case 'KeyP': this.videoController?.pause(); break;
        case 'KeyS': this.videoController?.stop(); break;
        case 'Escape': this.clearAll(); break;
      }
    });
  }

  validateEnvironment() {
    if (typeof fetch === 'undefined') {
      this.showError('Browser does not support required APIs');
      throw new Error('Unsupported browser');
    }
    if (!this.ctx) {
      this.showError('Canvas not supported');
      throw new Error('Canvas not supported');
    }
    if (typeof WebSocket === 'undefined') {
      this.showError('Browser does not support WebSockets');
      throw new Error('WebSocket not supported');
    }
  }

  async handleFileSelect(event) {
    const file = event.target.files[0];
    if (!file) return;

    const validation = this.validateFile(file);
    if (!validation.valid) {
      this.showError(validation.message);
      return;
    }

    this.state.currentFile = file;
    await this.processFile(file);
  }

  validateFile(file) {
    const maxSize = 100 * 1024 * 1024; // 100MB
    const allowedTypes = [
      'image/jpeg', 'image/png', 'image/webp',
      'video/mp4', 'video/webm', 'video/avi'
    ];

    if (!allowedTypes.includes(file.type)) {
      return { valid: false, message: 'Unsupported file type' };
    }

    if (file.size > maxSize) {
      return { valid: false, message: 'File too large (max 100MB)' };
    }

    return { valid: true };
  }

  async processFile(file) {
    this.setProcessingState(true);
    const isVideo = file.type.startsWith('video/');

    // Use progress bar for video instead of blocking overlay
    if (!isVideo) {
      this.showLoading();
    }
    this.showStatus('Processing file...', 'loading', false);

    try {
      if (file.type.startsWith('image/')) {
        await this.processImage(file);
        this.showStatus('Processing complete!', 'success', true);
      } else if (isVideo) {
        await this.processVideo(file);
      }
    } catch (error) {
      console.error('Processing error:', error);
      this.showError(`Processing failed: ${error.message}`);
    } finally {
      if (!isVideo) {
        this.hideLoading();
      }
      this.setProcessingState(false);
    }
  }



  async processImage(file) {
    const img = await this.loadImage(file);
    this.setupCanvas(img.width, img.height);
    this.ctx.drawImage(img, 0, 0);

    const response = await this.callDetectionAPI(file, this.apiConfig.image);
    this.drawDetections(response.detections, img.width, img.height);
  }


  async processVideo(file) {
    const videoUrl = URL.createObjectURL(file);
    this.state.mediaUrl = videoUrl;

    this.video.src = videoUrl;
    await this.waitForVideoMetadata();
    this.setupCanvas(this.video.videoWidth, this.video.videoHeight);

    this.videoOptions.classList.remove('hidden');

    // Phase 1: Upload video and get session metadata
    this.showStatus('Uploading video...', 'loading', false);
    const uploadResponse = await this.uploadVideoForStreaming(file);
    this.state.sessionId = uploadResponse.session_id;
    this.state.videoMeta = uploadResponse;

    // Phase 2: Set up playback immediately (detections fill in as they stream)
    this.showStatus('Processing video — you can press Play now', 'loading', false);
    this.showProgress(uploadResponse.total_frames);
    this.state.streamedDetections = new Array(uploadResponse.total_frames);

    const detectionData = {
      video_detections: this.state.streamedDetections,
      fps: uploadResponse.fps,
    };
    this.videoController = this.createVideoController(detectionData, this.video);
    this.enableControls();

    // Phase 3: Stream detections in background (playback already available)
    await this.streamVideoDetections(uploadResponse);
  }

  async uploadVideoForStreaming(file) {
    const formData = new FormData();
    formData.append('file', file);

    const response = await fetch(this.apiConfig.videoUpload, {
      method: 'POST',
      body: formData,
      credentials: 'same-origin',
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Upload failed ${response.status}: ${errorText}`);
    }

    return await response.json();
  }

  streamVideoDetections(videoMeta) {
    return new Promise((resolve, reject) => {
      const wsUrl = `${this.apiConfig.wsBase}/ws/predict_video`;
      const ws = new WebSocket(wsUrl);
      this.state.ws = ws;
      this.processingStartTime = performance.now();

      ws.onopen = () => {
        ws.send(JSON.stringify({
          action: 'start',
          session_id: videoMeta.session_id,
          frame_skip: parseInt(this.frameSkipInput.value, 10),
          confidence_threshold: parseFloat(this.confThresholdInput.value),
        }));
      };

      ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);

        switch (msg.type) {
          case 'start':
            break;

          case 'frame_result':
            this.handleFrameResult(msg, videoMeta.total_frames);
            break;

          case 'complete':
            this.handleStreamComplete(msg);
            this.hideProgress();
            resolve();
            break;

          case 'error':
            reject(new Error(msg.message));
            break;
        }
      };

      ws.onerror = () => {
        reject(new Error('WebSocket connection error'));
      };

      ws.onclose = (event) => {
        this.state.ws = null;
        if (!event.wasClean && event.code !== 1000) {
          reject(new Error(`WebSocket closed unexpectedly (code ${event.code})`));
        }
      };
    });
  }

  handleFrameResult(msg, totalFrames) {
    this.state.streamedDetections[msg.frame_index] = msg.detections;

    // Autoplay on first frame result
    if (msg.frame_index === 0 && this.videoController) {
      this.videoController.play();
    }

    const pct = Math.round(msg.progress * 100);
    this.progressBar.style.width = `${pct}%`;
    this.progressBar.setAttribute('aria-valuenow', pct);
    this.progressText.textContent = `${pct}%`;
    this.progressFrames.textContent = `${msg.frame_index + 1} / ${totalFrames} frames`;

    const elapsed = performance.now() - this.processingStartTime;
    if (msg.progress > 0.01) {
      const totalEstimate = elapsed / msg.progress;
      const remaining = totalEstimate - elapsed;
      const remainingSec = Math.ceil(remaining / 1000);
      if (remainingSec > 0) {
        this.progressEta.textContent = `~${remainingSec}s remaining`;
      }
    }
  }

  handleStreamComplete(msg) {
    const totalSec = (msg.total_time_ms / 1000).toFixed(1);
    const status = msg.cancelled
      ? `Cancelled after ${msg.total_frames_processed} frames`
      : `Done! ${msg.total_frames_sent} frames in ${totalSec}s (avg ${msg.avg_inference_ms}ms/frame)`;
    this.showStatus(status, 'success', true);
  }

  showProgress(totalFrames) {
    this.progressSection.classList.remove('hidden');
    this.progressBar.style.width = '0%';
    this.progressText.textContent = '0%';
    this.progressFrames.textContent = `0 / ${totalFrames} frames`;
    this.progressEta.textContent = '';
  }

  hideProgress() {
    setTimeout(() => {
      this.progressSection.classList.add('hidden');
    }, 3000);
  }


  loadImage(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      const reader = new FileReader();
      
      reader.onload = (e) => { img.src = e.target.result; };
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('Failed to load image'));
      
      reader.readAsDataURL(file);
    });
  }

  waitForVideoMetadata() {
    return new Promise((resolve, reject) => {
      if (this.video.readyState >= 1) {
        resolve();
      } else {
        this.video.onloadedmetadata = resolve;
        this.video.onerror = () => reject(new Error('Failed to load video metadata'));
        setTimeout(() => reject(new Error('Metadata timeout')), this.apiConfig.timeout);
      }
    });
  }

  async callDetectionAPI(file, endpoint) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), this.apiConfig.timeout);

    try {
      const formData = new FormData();
      formData.append('file', file);
      
      // Add CSRF token if available
      const csrfToken = this.getCsrfToken();
      if (csrfToken) {
        formData.append('csrfmiddlewaretoken', csrfToken);
      }

      const response = await fetch(endpoint, {
        method: 'POST',
        body: formData,
        signal: controller.signal,
        credentials: 'same-origin'
      });

      clearTimeout(timeoutId);

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`API error ${response.status}: ${errorText}`);
      }

      const data = await response.json();
      this.validateApiResponse(data, endpoint.includes('video'));
      return data;
    } catch (error) {
      if (error.name === 'AbortError') {
        throw new Error('Request timeout');
      }
      throw error;
    }
  }


  validateApiResponse(data, isVideo) {
    if (isVideo) {
      if (!data.video_detections || !Array.isArray(data.video_detections)) {
        throw new Error('Invalid video detection format');
      }
    } else {
      if (!data.detections || !Array.isArray(data.detections)) {
        throw new Error('Invalid image detection format');
      }
    }
  }

  getCsrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content ||
           document.cookie.match(/csrftoken=([^;]+)/)?.[1];
  }

  setupCanvas(width, height) {
    this.canvas.width = width;
    this.canvas.height = height;
    this.canvas.style.display = 'block';
    this.video.style.display = 'none';
  }

  drawDetections(detections, originalWidth, originalHeight) {
    // Use intrinsic canvas width/height, not client size
    const scaleX = this.canvas.width / originalWidth;
    const scaleY = this.canvas.height / originalHeight;

    this.ctx.save();
    this.ctx.lineWidth = 2;
    this.ctx.strokeStyle = 'red';
    this.ctx.fillStyle = 'red';
    this.ctx.font = `16px Arial`;

    const confThreshold = parseFloat(this.confThresholdInput?.value || 0);

    detections.forEach(detection => {
      if (detection.confidence < confThreshold) return;
      const [xmin, ymin, xmax, ymax] = detection.bbox;
      const width = (xmax - xmin) * scaleX;
      const height = (ymax - ymin) * scaleY;
      const x = xmin * scaleX;
      const y = ymin * scaleY;

      this.ctx.strokeRect(x, y, width, height);

      const label = `${detection.class_name} (${(detection.confidence * 100).toFixed(1)}%)`;

      // Adjust label position in intrinsic canvas coords
      const textY = y > 20 ? y - 5 : y + 15;
      this.ctx.fillText(label, x, textY);
    });

    this.ctx.restore();
  }


  createVideoController(detections, video) {
    const fps = detections.fps || 30;
    const frameDuration = 1 / fps;
    let playing = false;
    let rafId = null;

    const render = () => {
      if (!playing) return;

      const currentFrame = Math.floor(video.currentTime / frameDuration);
      if (currentFrame >= detections.video_detections.length) {
        pause();
        return;
      }

      const frameDetections = detections.video_detections[currentFrame] || [];

      this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
      this.ctx.drawImage(video, 0, 0);
      this.drawDetections(frameDetections, video.videoWidth, video.videoHeight);

      rafId = requestAnimationFrame(render);
    };

    const play = () => {
      if (!playing) {
        playing = true;
        video.play().catch(console.error);
        rafId = requestAnimationFrame(render);
      }
    };

    const pause = () => {
      playing = false;
      video.pause();
      cancelAnimationFrame(rafId);
    };

    const stop = () => {
      playing = false;
      cancelAnimationFrame(rafId);
      video.pause();
      video.currentTime = 0;
      this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    };

    return { play, pause, stop };
  }


  setProcessingState(processing) {
    this.isProcessing = processing;
    this.uploadInput.disabled = processing;
    this.enableControls(!processing);
    
    const buttons = [this.playBtn, this.pauseBtn, this.stopBtn];
    buttons.forEach(btn => btn.disabled = processing || !this.videoController);
  }

  enableControls(enable = true) {
    const buttons = [this.playBtn, this.pauseBtn, this.stopBtn];
    buttons.forEach(btn => btn.disabled = !enable);
  }

  showStatus(message, type = 'info', autoHide = false) {
    this.statusEl.textContent = message;
    this.statusEl.className = `status ${type}`;
    this.statusEl.classList.remove('hidden');

    // Only hide automatically if autoHide=true
    if (autoHide) {
      setTimeout(() => this.statusEl.classList.add('hidden'), 5000);
    }
  }


  showError(message) {
    this.errorEl.textContent = message;
    this.errorEl.classList.remove('hidden');
    setTimeout(() => this.errorEl.classList.add('hidden'), 10000);
  }

  showLoading() {
    document.getElementById('loading-overlay').style.display = 'flex';

    // Optionally dim main UI container
    document.querySelector('body').style.pointerEvents = 'none';  // disable clicks
    document.querySelector('body').style.opacity = '0.6';          // dim UI
  }

  hideLoading() {
    document.getElementById('loading-overlay').style.display = 'none';

    document.querySelector('body').style.pointerEvents = 'auto';   // re-enable clicks
    document.querySelector('body').style.opacity = '1';            // restore UI
  }


  clearAll() {
    // Close WebSocket if active
    if (this.state.ws) {
      try {
        this.state.ws.send(JSON.stringify({ action: 'cancel' }));
      } catch (_) { /* ws may already be closed */ }
      this.state.ws.close();
      this.state.ws = null;
    }

    this.progressSection?.classList.add('hidden');
    this.videoOptions?.classList.add('hidden');

    URL.revokeObjectURL(this.state.mediaUrl);
    this.videoController = null;
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.canvas.style.display = 'none';
    this.video.style.display = 'none';
    this.uploadInput.value = '';
    this.state = {
      ...this.state,
      currentFile: null,
      mediaUrl: null,
      streamedDetections: [],
      sessionId: null,
      videoMeta: null,
    };
    this.enableControls(false);
    this.hideMessages();
  }

  hideMessages() {
    this.statusEl.classList.add('hidden');
    this.errorEl.classList.add('hidden');
  }
}

// Initialize when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  try {
    new PlayerDetectionApp();
  } catch (error) {
    console.error('Failed to initialize app:', error);
    document.body.innerHTML = '<div style="text-align:center;padding:2rem;color:red;">Application failed to initialize</div>';
  }
});

// Expose for debugging/testing
window.PlayerDetectionApp = PlayerDetectionApp;