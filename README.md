# Football Player Detection with MLOps

![YOLOv11](https://img.shields.io/badge/Model-YOLOv11-blue)
![FastAPI](https://img.shields.io/badge/API-FastAPI-green)
![Docker](https://img.shields.io/badge/Container-Docker-blue)
![Terraform](https://img.shields.io/badge/IaC-Terraform-purple)
![AWS](https://img.shields.io/badge/Cloud-AWS-orange)
![GitHub Actions](https://img.shields.io/badge/CI/CD-GitHub_Actions-lightgrey)

<!-- Teaser Prediction Video -->
<p align="center">
  <video src="https://github.com/smh-hosseiny/football-player-detection-mlops/raw/main/assets/pred.mp4" controls width="75%">
    Your browser does not support the video tag.
  </video>
</p>

---

This repository contains a full-stack, production-ready MLOps pipeline for detecting football players in images and videos. It leverages state-of-the-art tools to automate the entire lifecycle of a machine learning model, from training and experiment tracking to deployment and monitoring.

The system uses a **YOLOv11** model for high-performance object detection, which is served via a scalable **FastAPI** backend. The entire cloud infrastructure is defined as code using **Terraform** and deployed on **AWS**. A complete **CI/CD pipeline** with **GitHub Actions** automates the build, test, and deployment process to a containerized environment on **Amazon ECS**, ensuring robust and repeatable deployments.

The live application can be accessed at: **[https://playerdetect.com](https://playerdetect.com)**
