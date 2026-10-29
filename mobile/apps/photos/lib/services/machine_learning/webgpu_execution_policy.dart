final webGpuExecutionPolicy = WebGpuExecutionPolicy();

/// Filen fork: the GPU (WebGPU) path of the on-device ML is never used. It crashed the whole app
/// with a SIGSEGV inside libonnxruntime on a Pixel; the CPU/XNNPACK path is slower but stable.
class WebGpuExecutionPolicy {
  Future<bool> isEligible() async => false;
}
