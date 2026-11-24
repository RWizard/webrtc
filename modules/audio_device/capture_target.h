/*
 *  Dada (#321): с какого микрофона пишет захват HAL (hal_capture.mm) — при явном выборе и в режиме «по умолчанию».
 *
 *  Инвариант: захват пишет только с устройства, которое человек видит в списке выбора, и источник правды (снимок захвата, поле
 *  target) заранее говорит, с какого устройства запишет. Поэтому «что считать микрофоном» здесь — ровно правило списка
 *  приложения Dada: InputRestore.listable и InputRestore.isSynthetic (apps/mobile/plugins/mac-catalyst/InputRestore.swift);
 *  меняется одно — меняется и другое. Вход системы, которого в списке нет (виртуальный: BlackHole, Loopback, Krisp; составной:
 *  агрегат Audio MIDI Setup, CADefaultDeviceAggregate; скрытый; без потока ввода), режим «по умолчанию» не берёт: пишет первое
 *  показываемое устройство по порядку Core Audio — его же приложение показывает первым. Явный выбор, которого нет или который
 *  показать нельзя, пишет как «по умолчанию» с причиной not_found.
 *
 *  Чистый C++17 без WebRTC и Core Audio: свойства устройств читает hal_capture.mm. Копия файла с проверкой лежит в репозитории
 *  Dada (apps/mobile/plugins/mac-webrtc/fork/audio_device, tests/c/CaptureTargetCheck.cpp).
 */
#ifndef MODULES_AUDIO_DEVICE_CAPTURE_TARGET_H_
#define MODULES_AUDIO_DEVICE_CAPTURE_TARGET_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace webrtc {

// Устройство Core Audio так, как его видит список приложения.
struct CaptureDevice {
  uint32_t id = 0;               // AudioObjectID
  std::string uid;               // kAudioDevicePropertyDeviceUID; пусто — не прочитался: приложение такое не перечисляет
  bool has_input = false;        // есть поток ввода (kAudioDevicePropertyStreams, область ввода)
  bool hidden = false;           // kAudioDevicePropertyIsHidden == 1
  uint32_t transport = 0;        // kAudioDevicePropertyTransportType; 0 — не прочитался
  bool aggregate_class = false;  // класс объекта — kAudioAggregateDeviceClassID
};

struct CaptureTarget {
  uint32_t id = 0;  // 0 — писать не с чего
  std::string uid;
  std::string error;  // пусто; not_found — явного нет или его не показать, пишет «по умолчанию»; no_device — не с чего
};

constexpr uint32_t CaptureFourCC(const char (&code)[5]) {
  return (static_cast<uint32_t>(static_cast<unsigned char>(code[0])) << 24) |
         (static_cast<uint32_t>(static_cast<unsigned char>(code[1])) << 16) |
         (static_cast<uint32_t>(static_cast<unsigned char>(code[2])) << 8) |
         static_cast<uint32_t>(static_cast<unsigned char>(code[3]));
}

// Составное или виртуальное — InputRestore.isSynthetic: класс агрегата, транспорт «агрегат» ('grup') или «виртуальный» ('virt').
// Транспорт не прочитался — не гадаем: устройство настоящее.
inline bool IsSyntheticInput(uint32_t transport, bool aggregate_class) {
  return aggregate_class || transport == CaptureFourCC("grup") || transport == CaptureFourCC("virt");
}

// Сырые чтения свойств Core Audio → устройство: толкование ровно как у списка приложения (DadaAudioInput.inputs) — IsHidden
// скрывает только прочитанная 1; транспорт не прочитался — 0, настоящее; класс агрегата — только прочитанный
// kAudioAggregateDeviceClassID ('aagg', hal_capture.mm сверяет его с Core Audio); вход — хотя бы один поток ввода. nullopt — свойство
// не прочиталось. hal_capture.mm (ReadDevices) только читает и зовёт это.
inline CaptureDevice MakeCaptureDevice(uint32_t id, std::string uid, size_t input_streams, std::optional<uint32_t> hidden,
                                       std::optional<uint32_t> transport, std::optional<uint32_t> object_class) {
  CaptureDevice device;
  device.id = id;
  device.uid = std::move(uid);
  device.has_input = input_streams > 0;
  device.hidden = hidden == 1u;
  device.transport = transport.value_or(0);
  device.aggregate_class = object_class == CaptureFourCC("aagg");
  return device;
}

// Устройство можно показать и открыть — InputRestore.listable (поток ввода, не скрыто, не составное и не виртуальное) и uid, без
// которого DadaAudioInput.inputs() устройство не перечисляет.
inline bool IsListableInput(const CaptureDevice& device) {
  return !device.uid.empty() && device.has_input && !device.hidden &&
         !IsSyntheticInput(device.transport, device.aggregate_class);
}

// devices — по порядку kAudioHardwarePropertyDevices; system_default — kAudioHardwarePropertyDefaultInputDevice (0 — нет);
// explicit_choice — явный выбор requested_uid, иначе «по умолчанию».
inline CaptureTarget ChooseCaptureTarget(const std::vector<CaptureDevice>& devices, uint32_t system_default,
                                         bool explicit_choice, const std::string& requested_uid) {
  const CaptureDevice* chosen = nullptr;
  if (explicit_choice) {
    for (const CaptureDevice& device : devices) {
      if (device.uid == requested_uid && IsListableInput(device)) {
        chosen = &device;
        break;
      }
    }
  }
  for (const CaptureDevice& device : devices) {
    if (chosen == nullptr && device.id == system_default && IsListableInput(device)) chosen = &device;
  }
  for (const CaptureDevice& device : devices) {
    if (chosen == nullptr && IsListableInput(device)) chosen = &device;
  }
  if (chosen == nullptr) return {0, std::string(), "no_device"};
  const bool fallback = explicit_choice && chosen->uid != requested_uid;
  return {chosen->id, chosen->uid, fallback ? "not_found" : std::string()};
}

}  // namespace webrtc

#endif  // MODULES_AUDIO_DEVICE_CAPTURE_TARGET_H_
