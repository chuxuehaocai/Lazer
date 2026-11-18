#ifndef RUNNER_WINDOW_BACKDROP_H_
#define RUNNER_WINDOW_BACKDROP_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>

class WindowBackdrop {
 public:
  WindowBackdrop(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowBackdrop();
  void HandleWindowMessage(UINT message);
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
