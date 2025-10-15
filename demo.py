import sys

import cv2  # Only for video capture or your source
from PyQt6.QtGui import QImage, QPixmap
from PyQt6.QtWidgets import QApplication, QLabel, QVBoxLayout, QWidget
from ultralytics import YOLO


class VideoDemo(QWidget):
    def __init__(self, model_path, video_path):
        super().__init__()
        self.model = YOLO(model_path)
        self.cap = cv2.VideoCapture(video_path)
        self.label = QLabel()
        self.layout = QVBoxLayout()
        self.layout.addWidget(self.label)
        self.setLayout(self.layout)

        self.timer = self.startTimer(30)  # roughly 33fps

    def timerEvent(self, event):
        ret, frame = self.cap.read()
        if not ret:
            self.cap.release()
            self.killTimer(self.timer)
            return

        results = self.model(frame)
        frame_with_boxes = results[0].plot()

        # Convert to Qt image
        h, w, ch = frame_with_boxes.shape
        bytes_per_line = ch * w
        qt_img = QImage(
            frame_with_boxes.data, w, h, bytes_per_line, QImage.Format.Format_BGR888
        )
        self.label.setPixmap(QPixmap.fromImage(qt_img))


if __name__ == "__main__":
    app = QApplication(sys.argv)
    demo = VideoDemo(
        model_path="./src/models/best.pt", video_path="./src/data/video.mp4"
    )
    demo.show()
    sys.exit(app.exec())
