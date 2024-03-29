#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <sstream>
#include <chrono>
#include <thread>
#include <nvml.h>
#pragma comment(lib, "nvml")

#define sleep(t) std::this_thread::sleep_for(std::chrono::milliseconds(t))

// const float bytes_per_gb = (1 << 30);
const float bytes_per_gb = (1 << 30);
const float bytes_per_mib = (1 << 20);
const float ms_per_hour = 1000 * 3600;
const int max_grid_dim = (1 << 15);
const int max_block_dim = 1024;
const int max_sleep_time = 1e3;
const float sleep_interval = 1e16;
const int max_gpu_num = 32;

__global__ void default_script_kernel(char* array, size_t occupy_size) {
  size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= occupy_size) return;
  array[i]++;
}

void launch_default_script(char** array, size_t occupy_size,
                           std::vector<int>& grid_dim,
                           std::vector<int>& gpu_ids) {
  int gd = std::min(grid_dim[rand() % grid_dim.size()],
                    int(occupy_size / max_block_dim));
  for (int id : gpu_ids) {
    cudaSetDevice(id);
    default_script_kernel<<<gd, max_block_dim, 0, NULL>>>(array[id],
                                                          occupy_size);
  }
}

void run_default_script(char** array, size_t occupy_size, float total_time,
                        std::vector<int>& gpu_ids) {
  printf("Running default script >>>>>>>>>>>>>>>>>>>>\n");
  for (int id : gpu_ids) {
    cudaSetDevice(id);
    // cudaDeviceSynchronize();
    cudaError_t status = cudaMalloc(&array[id], occupy_size);
  }
  srand(time(NULL));
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);
  float time;
  size_t cnt = 0, sleep_time;
  std::vector<int> grid_dim;
  for (int i = 1; i <= max_grid_dim; i <<= 1) {
    grid_dim.push_back(i);
  }
  cudaEventRecord(start, 0);
  while (true) {
    launch_default_script(array, occupy_size, grid_dim, gpu_ids);
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time, start, stop);
    if (time / ms_per_hour > total_time) break;
    if (!((++cnt) % size_t(sleep_interval / occupy_size))) {
      cnt = 0;
      printf("Occupied time: %.2f hours\n", time / ms_per_hour);
      sleep_time = rand() % max_sleep_time + 1;
      sleep(sleep_time);
    }
  }
  cudaEventDestroy(start);
  cudaEventDestroy(stop);
  for (int id : gpu_ids) {
    cudaFree(array[id]);
  }
}

void process_args(int argc, char** argv, size_t& occupy_size, float& total_time,
                  std::vector<int>& gpu_ids, std::string& script_path) {
  if (argc < 4) {
    printf(
        "Arguments: <**any dummy augments**>  <GPU Memory (MiB)> <Occupied Time (h)> <GPU ID> <OPTIONAL: "
        "Script Path>\n");
    throw std::invalid_argument("Invalid argument number");
  }
  int gpu_num;
  cudaGetDeviceCount(&gpu_num);
  int id;
  std::string s(argv[3]);
  std::replace(s.begin(), s.end(), ',', ' ');
  std::stringstream ss;
  ss << s;
  while (ss >> id) {
    gpu_ids.push_back(id);
  }
  if (gpu_ids.size() == 1 && gpu_ids[0] == -1) {
    gpu_ids[0] = 0;
    for (int i = 1; i < gpu_num; ++i) {
      gpu_ids.push_back(i);
    }
  }
  for (int i : gpu_ids) {
    if (i < 0 || i >= gpu_num) {
      printf("Invalid GPU ID (%d GPU in total): %d\n", i, gpu_num);
      throw std::invalid_argument("Invalid GPU ID");
    }
  }

  float occupy_mem;
  size_t total_size, avail_size;
  cudaMemGetInfo(&avail_size, &total_size);
  sscanf(argv[1], "%f", &occupy_mem);
  sscanf(argv[2], "%f", &total_time);
  if (occupy_mem <= 0) {
    printf("GPU memory must be positive: %.2f\n", occupy_mem);
    throw std::invalid_argument("Invalid GPU memory");
  }
  if (total_time < 0) {
    printf("Occupied time must be positive: %.2f\n", total_time);
    throw std::invalid_argument("Invalid occupied time");
  }
  occupy_size = occupy_mem * bytes_per_mib;
  if (occupy_size > total_size) {
    printf("GPU memory exceeds maximum (%.2f MiB): %.2f\n",
           total_size / bytes_per_mib, occupy_mem);
    throw std::invalid_argument("Exceed maximal GPU memory");
  }

  printf("GPU memory (MiB): %.2f\n", occupy_mem);
  printf("Occupied time (h): %.2f\n", total_time);
  if (argc == 4) {
    printf("GPU ID: ");
    for (int id = 0; id < gpu_ids.size(); ++id) {
      printf("%d%c", gpu_ids[id], ",\n"[id == gpu_ids.size() - 1]);
    }
  } else {
    script_path = argv[4];
    printf("Script path: %s\n", script_path.c_str());
  }

}

void allocate_mem(char** array, size_t occupy_size, std::vector<int>& gpu_ids) {
  std::vector<bool> allocated(max_gpu_num, false);
  int cnt = 0;
  
  while (true) {
    printf("Clean & Try allocate GPU memory %d times >>>>>>>>>>>>>>>>>>>>\n", ++cnt);
    cudaDeviceReset();
    bool all_allocated = true;
    for (int id : gpu_ids) {
      if (!allocated[id]) {
        nvmlDevice_t device;
        nvmlReturn_t device_handle = nvmlDeviceGetHandleByIndex(id, &device);
        // cudaSetDevice(id);
        // cudaError_t status = cudaMalloc(&array[id], occupy_size);
        nvmlMemory_t memory;
        nvmlReturn_t memory_return = nvmlDeviceGetMemoryInfo(device, &memory);

        // unsigned long long total_size = memory.total;
        // unsigned long long used_size = memory.used;
        unsigned long long free_size = memory.free;
        // cudaMemGetInfo(&avail_size, &total_size);
        // if (status != cudaSuccess) 
        if (occupy_size > free_size)
        {
          printf(
              "GPU-%d: Failed to allocate %.2f MiB GPU memory (%.2f MiB "
              "available)\n",
              id, occupy_size / bytes_per_mib, free_size / bytes_per_mib);
          all_allocated = false;
          // break;
        } 
        else 
        {
          // if (status == cudaSuccess)
          // {
          //   allocated[id] = true;
          //   printf(
          //       "GPU-%d: Successfully allocate %.2f GB GPU memory (%.2f GB "
          //       "available)\n",
          //       id, occupy_size / bytes_per_gb, free_size / bytes_per_gb);
          // } 
          // else 
          // {
          //   printf("GPU-%d: Error %d\n", id, status);
          //   all_allocated = false;
          // }
          allocated[id] = true;
          printf(
              // "GPU-%d: Successfully allocate %.2f GB GPU memory (%.2f GB "
              // "available)\n",
              // id, occupy_size / bytes_per_gb, free_size / bytes_per_gb

              "GPU-%d: Successfully allocate %.2f MiB GPU memory (%.2f MiB "
              "available)\n",
              id, occupy_size / bytes_per_mib, free_size / bytes_per_mib
              );
        }
      }
    }
    
    if (all_allocated) break;
    sleep(5000);
  }
  printf("Successfully allocate memory on all GPUs!\n");
}

void run_custom_script(char** array, std::vector<int>& gpu_ids,
                       std::string script_path) {
  // std::cin.get();
  printf("Running custom script >>>>>>>>>>>>>>>>>>>>\n");
  // cudaDeviceReset();
  // std::cin.get();
  // for (int id : gpu_ids) {
  //   cudaFree(array[id]);
  // }
  // // cudaDeviceReset();
  // std::cin.get();
  nvmlShutdown();
  // std::cin.get();
  std::string cmd = "sh " + script_path;
  std::system(cmd.c_str());
}

bool has_suffix(const std::string &str, const std::string &suffix)
{
    return str.size() >= suffix.size() &&
           str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
}

int main(int argc, char** argv) {
  size_t occupy_size;
  float total_time;
  std::vector<int> gpu_ids;
  std::string script_path;
  char* array[max_gpu_num];
  bool run_custom = false;

  int real_argc = argc;
  char** real_argv = argv;

  // Process arguments
  if (argc < 4) {
    printf(
        "Arguments: <**any dummy augments**>  <GPU Memory (MiB)> <Occupied Time (h)> <GPU ID> <OPTIONAL: "
        "Script Path>\n");
    printf("Example 1: Occupy 16000 MB GPU memory for 24 hours using GPU 0, 1, 2, 3 to run default script.\n");
    printf("./gpu_mon 0 16000 24 0,1,2,3\n");
    printf("Example 2: Occupy 16000 MB GPU memory for 24 hours using GPU 0, 1, 2, 3 to run custom script `run.sh`.\n");
    printf("./gpu_mon 0 16000 24 0,1,2,3 run.sh\n");
    printf("Example 3: Occupy 16000 MB GPU memory for 24 hours using GPU 0, 1, 2, 3 to run default script, with some dummy augrments\n");
    printf("./gpu_mon dummy_arg1 dummy_arg2 0 16000 24 0,1,2,3\n");
    throw std::invalid_argument("Invalid argument number");
  } else {
    // if the last argv is end with .sh
    if (has_suffix(argv[argc-1], ".sh"))
    {
      // run custom script
      run_custom = true;
      real_argc = 5;
    } else {
      // run default script
      run_custom = false;
      real_argc = 4;
    }

    // remove dummy augments in real_argv and only keep the the first, and last number of real_argc augments
    real_argv = new char*[real_argc];
    real_argv[0] = argv[0]; // filename
    for (int i = 1; i < real_argc; ++i)
    {
      real_argv[i] = argv[argc-real_argc+i];
    }
  }

  // print to check real_argc and real_argv
  printf("real_argc: %d\n", real_argc);
  for (int i = 0; i < real_argc; ++i)
  {
    printf("real_argv[%d]: %s\n", i, real_argv[i]);
  }

  nvmlReturn_t init_ptr;
  init_ptr = nvmlInit();


  if (init_ptr == NVML_SUCCESS){
    process_args(real_argc, real_argv, occupy_size, total_time, gpu_ids, script_path);
    cudaDeviceReset();
    allocate_mem(array, occupy_size, gpu_ids);
  
    if (run_custom == false) {
      run_default_script(array, occupy_size, total_time, gpu_ids);
    } else {
      run_custom_script(array, gpu_ids, script_path);
    }

    // nvmlShutdown();

    return 0;
  }
}
