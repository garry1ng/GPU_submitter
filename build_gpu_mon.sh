#!/bin/bash

nvcc gpu_mon.cu -o gpu_mon -lnvidia-ml && cp gpu_mon bin/ && mv gpu_mon python3.11
