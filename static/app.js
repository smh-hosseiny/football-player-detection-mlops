class PlayerDetectionApp {
  constructor() {
    this.apiConfig = {
      image: window.API_ENDPOINTS?.image || '/api/predict',
      video: window.API_ENDPOINTS?.video || '/api/predict-video',
      timeout: 30000 // 30 seconds
    };
    
    this.state = {
      currentFile: null,
      isProcessing: false,
      videoController: null,
      mediaUrl: null
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
  }

  bindEvents() {
    this.uploadInput.addEventListener('change', (e) => this.handleFileSelect(e));
    this.clearBtn.addEventListener('click', () => this.clearAll());
    this.playBtn.addEventListener('click', () => this.videoController?.play());
    this.pauseBtn.addEventListener('click', () => this.videoController?.pause());
    this.stopBtn.addEventListener('click', () => this.videoController?.stop());
    
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
    this.showStatus('Processing file...', 'loading');

    try {
      if (file.type.startsWith('image/')) {
        await this.processImage(file);
      } else if (file.type.startsWith('video/')) {
        await this.processVideo(file);
      }
      this.showStatus('Processing complete!', 'success');
    } catch (error) {
      console.error('Processing error:', error);
      this.showError(`Processing failed: ${error.message}`);
    } finally {
      this.setProcessingState(false);
    }
  }

  async processImage(file) {
    const img = await this.loadImage(file);
    this.setupCanvas(img.width, img.height);
    this.ctx.drawImage(img, 0, 0);

    const detections = await this.callDetectionAPI(file, this.apiConfig.image);
    this.drawDetections(detections, img.width, img.height);
  }

  async processVideo(file) {
    const videoUrl = URL.createObjectURL(file);
    this.state.mediaUrl = videoUrl;
    
    this.video.src = videoUrl;
    await this.waitForVideoMetadata();

    const detections = await this.callDetectionAPI(file, this.apiConfig.video);
    this.setupCanvas(this.video.videoWidth, this.video.videoHeight);
    
    this.videoController = this.createVideoController(detections, this.video);
    this.enableControls();
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
    const scaleX = this.canvas.clientWidth / originalWidth;
    const scaleY = this.canvas.clientHeight / originalHeight;

    this.ctx.save();
    this.ctx.scale(scaleX, scaleY);
    this.ctx.lineWidth = 2 / scaleX;
    this.ctx.strokeStyle = '#ff0000';
    this.ctx.fillStyle = '#ff0000';
    this.ctx.font = `${16 / scaleX}px Arial`;

    detections.forEach(detection => {
      const [x, y, w, h] = [
        detection.bbox[0], detection.bbox[1],
        detection.bbox[2] - detection.bbox[0],
        detection.bbox[3] - detection.bbox[1]
      ];

      this.ctx.strokeRect(x, y, w, h);
      
      const label = `${detection.class_name} (${(detection.confidence * 100).toFixed(1)}%)`;
      const textY = y > 20 ? y - 5 : y + 15;
      this.ctx.fillText(label, x, textY / scaleY);
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
      const frameDetections = detections.video_detections[currentFrame] || [];

      this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
      this.ctx.drawImage(video, 0, 0);
      this.drawDetections(frameDetections, video.videoWidth, video.videoHeight);

      if (currentFrame < detections.video_detections.length) {
        rafId = requestAnimationFrame(render);
      } else {
        this.pause();
      }
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

  showStatus(message, type = 'info') {
    this.statusEl.textContent = message;
    this.statusEl.className = `status ${type}`;
    this.statusEl.classList.remove('hidden');
    setTimeout(() => this.statusEl.classList.add('hidden'), 5000);
  }

  showError(message) {
    this.errorEl.textContent = message;
    this.errorEl.classList.remove('hidden');
    setTimeout(() => this.errorEl.classList.add('hidden'), 10000);
  }

  clearAll() {
    URL.revokeObjectURL(this.state.mediaUrl);
    this.videoController = null;
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.canvas.style.display = 'none';
    this.video.style.display = 'none';
    this.uploadInput.value = '';
    this.state = { ...this.state, currentFile: null, mediaUrl: null };
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