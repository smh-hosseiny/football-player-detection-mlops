const apiImg = "https://api.playersdetect.com/predict";
const apiVid = "https://api.playersdetect.com/predict_video";
const upload = document.getElementById("mediaUpload");
const canvas = document.getElementById("canvas");
const video = document.getElementById("video");
const ctx = canvas.getContext('2d');
let annotationController = null;

upload.addEventListener('change', event => {
  const file = event.target.files[0];
  if (!file) return;
  clearCanvas();
  console.log('Selected file:', file);
  console.log('Type:', file.type);
  console.log('Size:', file.size);
  if (file.type.startsWith('video/')) {
    processVideo(file);
  } else {
    processImage(file);
  }
});

function clearCanvas() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  canvas.style.display = "block";
  video.style.display = "none";
}

function processImage(file) {
  const img = new Image();
  img.onload = () => {
    canvas.width = img.width; canvas.height = img.height;
    ctx.drawImage(img, 0, 0);
    const formData = new FormData();
    formData.append("file", file);     
    fetch(apiImg, { method: "POST", body: formData })
    .then(r => r.json())
    .then(data => {
        console.log('API response:', data);
        if (data.detections && Array.isArray(data.detections)) {
        drawBoxes(data.detections);
        } else {
        alert('No detections returned from server.');
        }
    })
    .catch(error => {
        console.error('Error fetching detection:', error);
        alert('Error during detection.');
    });
    }
    
  const reader = new FileReader();
  reader.onload = e => { img.src = e.target.result; }
  reader.readAsDataURL(file);
}


async function processVideo(file) {
  // Create a URL for the original uploaded video file
  const url = URL.createObjectURL(file);
  video.src = url;
  video.pause(); // Prevent the video from autoplaying!
  video.style.display = "none";
  canvas.style.display = "none";

  // Optionally, show a loading indicator to user here

  const formData = new FormData();
  formData.append("file", file);

  try {
    const response = await fetch(apiVid, { method: "POST", body: formData });
    if (!response.ok) throw new Error(`Server error: ${response.status} ${response.statusText}`);
    const data = await response.json();
    if (!data.video_detections || !Array.isArray(data.video_detections) || data.video_detections.length === 0) {
      alert("No detections returned from server.");
      return;
    }

    await waitForMeta(video);

    video.style.display = "none";
    canvas.style.display = "block";

    // ✨ USE THE FPS FROM THE API, FALLBACK TO 30 IF NOT PROVIDED
    const fps = data.fps || 30; 
    console.log(`Using FPS: ${fps}`); // Log for debugging

    const controller = playAnnotatedVideo(video, data.video_detections, fps);

    document.getElementById('play').onclick = () => controller.play();
    document.getElementById('pause').onclick = () => controller.pause();
    document.getElementById('stop').onclick = () => controller.stop();

  } catch (error) {
    console.error("Error processing video:", error);
    alert("Error during video processing.");
  }
}




function waitForMeta(video) {
  return new Promise(res => {
    if (video.readyState >= 1) res();
    else video.onloadedmetadata = () => res();
  });
}



function drawBoxes(detections) {
  // ✨ CALCULATE SCALING RATIOS
  const scaleX = canvas.clientWidth / canvas.width;
  const scaleY = canvas.clientHeight / canvas.height;

  ctx.save(); // Save the original context state
  ctx.scale(scaleX, scaleY);

  ctx.lineWidth = 2 / scaleX; // Adjust line width to be consistent after scaling
  ctx.strokeStyle = 'red';
  ctx.font = `${16 / scaleX}px Arial`; // Adjust font size
  ctx.fillStyle = 'red';

  detections.forEach(detection => {
    const [xmin, ymin, xmax, ymax] = detection.bbox;
    const width = xmax - xmin;
    const height = ymax - ymin;

    // Draw bounding box (no manual scaling needed here now)
    ctx.strokeRect(xmin, ymin, width, height);

    // Draw label and confidence
    const label = `${detection.class_name} (${(detection.confidence * 100).toFixed(1)}%)`;
    const textYPosition = ymin > 20 ? ymin - (5 / scaleY) : ymin + (15 / scaleY);
    ctx.fillText(label, xmin, textYPosition);
  });
  
  ctx.restore(); // Restore the context to its original state (unscaled)
}



function playAnnotatedVideo(video, detectionsPerFrame, fps) {
  const totalFrames = detectionsPerFrame.length;
  const frameDuration = 1 / fps;

  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;

  let playing = false;
  let rafId = null;

  function render() {
    if (!playing) return;

    const currentFrame = Math.floor(video.currentTime / frameDuration);

    if (currentFrame >= totalFrames) {
      stop();
      return;
    }

    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    drawBoxes(detectionsPerFrame[currentFrame]);

    rafId = requestAnimationFrame(render);
  }

  function play() {
    if (!playing) {
      playing = true;
      video.play();
      rafId = requestAnimationFrame(render);
    }
  }

  function pause() {
    playing = false;
    video.pause();
    cancelAnimationFrame(rafId);
  }

  function stop() {
    playing = false;
    cancelAnimationFrame(rafId);
    video.pause();
    video.currentTime = 0;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
  }

  return { play, pause, stop };
}
