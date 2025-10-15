import cv2
from ultralytics import YOLO


class YoloPredictor:
    def __init__(self, model_path: str, device: str = "cuda"):
        self.model = YOLO(model_path)
        self.device = device

    def predict_image(self, image_path: str, conf: float = 0.25):
        image = cv2.imread(image_path)
        if image is None:
            raise FileNotFoundError(f"Could not load image: {image_path}")

        results = self.model(image, device=self.device, conf=conf)
        boxes = results[0].boxes.xyxy.cpu().numpy()
        scores = results[0].boxes.conf.cpu().numpy()
        classes = results[0].boxes.cls.cpu().numpy()
        names = results[0].names

        for box, score, cls_idx in zip(boxes, scores, classes):
            x1, y1, x2, y2 = [int(v) for v in box]
            label = names[int(cls_idx)]
            cv2.rectangle(image, (x1, y1), (x2, y2), (0, 255, 0), 2)
            cv2.putText(
                image,
                f"{label} {score:.2f}",
                (x1, y1 - 10),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.7,
                (0, 255, 0),
                2,
            )
        return boxes, scores, classes, image

    def predict_video(self, video_path: str, conf: float = 0.25, save_path: str = None):
        cap = cv2.VideoCapture(video_path)
        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        fps = cap.get(cv2.CAP_PROP_FPS)

        out = None
        if save_path:
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            out = cv2.VideoWriter(save_path, fourcc, fps if fps > 0 else 20.0, (w, h))

        frame_count = 0
        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break

            results = self.model(frame, device=self.device, conf=conf)[0]

            # Draw bounding boxes and labels
            for box, cls, score in zip(
                results.boxes.xyxy, results.boxes.cls, results.boxes.conf
            ):
                x1, y1, x2, y2 = map(int, box)
                class_id = int(cls)
                conf_score = float(score)
                label = f"{self.model.names[class_id]} {conf_score:.2f}"
                cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
                cv2.putText(
                    frame,
                    label,
                    (x1, y1 - 10),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.6,
                    (0, 255, 0),
                    2,
                )

            cv2.imshow("Detections", frame)
            if out:
                out.write(frame)

            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

            frame_count += 1

        cap.release()
        if out:
            out.release()
            print(f"✅ Video saved to {save_path}")
        cv2.destroyAllWindows()


# python predictor.py --input_path ../data/sample.jpg
# python predictor.py --input_path ../data/video.mp4 --save_path pred.mp4

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="YOLO model prediction demo")
    parser.add_argument(
        "--input_path", required=True, help="Path to input image or video"
    )
    parser.add_argument(
        "--model_path", default="../models/best.pt", help="Path to .pt model weights"
    )
    parser.add_argument(
        "--device", default="cuda", help="Device for inference ('cuda' or 'cpu')"
    )
    parser.add_argument("--conf", type=float, default=0.25, help="Confidence threshold")
    parser.add_argument(
        "--save_path",
        default=None,
        help="Path to save output (image or video, optional)",
    )

    args = parser.parse_args()
    predictor = YoloPredictor(args.model_path, args.device)

    input_path = args.input_path
    conf = args.conf
    save_path = args.save_path

    # Determine if input is image or video
    if input_path.lower().endswith((".jpg", ".jpeg", ".png")):
        boxes, scores, classes, image = predictor.predict_image(input_path, conf=conf)
        print("Detections:")
        for box, score, cls in zip(boxes, scores, classes):
            print(f"Box: {box}, Score: {score:.2f}, Class: {int(cls)}")

        if save_path:
            cv2.imwrite(save_path, image)
            print(f"✅ Saved result to {save_path}")

        cv2.imshow("Detections", image)
        cv2.waitKey(0)
        cv2.destroyAllWindows()

    elif input_path.lower().endswith((".mp4", ".avi", ".mov", ".mkv")):
        predictor.predict_video(input_path, conf=conf, save_path=save_path)

    else:
        raise ValueError("Unsupported input file format.")
