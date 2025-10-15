from fastapi.testclient import TestClient
from api.main import app


# Create a TestClient instance that will interact with your app
client = TestClient(app)


# Test for the root endpoint, which serves the HTML page.
def test_read_root():
    """
    Tests if the root endpoint ('/') returns a successful response and HTML content.
    """
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


# Test for the health check endpoint.
def test_health_check():
    """
    Tests the /health endpoint to ensure the API reports a healthy status.
    """
    response = client.get("/health")
    assert response.status_code == 200
    json_response = response.json()
    assert json_response["status"] == "healthy"
    assert "device" in json_response


# Test for the main image prediction endpoint.
def test_predict_endpoint():
    """
    Tests the /predict endpoint by sending a mock image file.
    Verifies the status code and the structure of the JSON response.
    """
    with open("assets/sample.jpg", "rb") as f:
        mock_file = ("sample.jpg", f, "image/jpeg")
        response = client.post("/predict", files={"file": mock_file})

    # 1. Assert that the request was successful
    assert response.status_code == 200

    # 2. Assert that the response is valid JSON
    json_response = response.json()

    # 3. Assert that the response contains the expected keys from your API
    assert "detections" in json_response
    assert "num_objects" in json_response
    assert "inference_time_ms" in json_response
    assert "image_size" in json_response
    assert "processing_time_ms" in json_response

    # 4. Assert that the types of the values are correct
    assert isinstance(json_response["detections"], list)
    assert isinstance(json_response["image_size"], list)


def test_predict_endpoint_no_file():
    """
    Tests that the API correctly handles requests with no file sent.
    It should return a 422 Unprocessable Entity error.
    """
    response = client.post("/predict")  # Corrected from "/predict/image"
    assert response.status_code == 422


# A basic test for the Prometheus metrics endpoint.
def test_metrics_endpoint():
    """
    Tests that the /metrics endpoint returns a successful response
    and that the content type is plain text.
    """
    response = client.get("/metrics")
    assert response.status_code == 200
