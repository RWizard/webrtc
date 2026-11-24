/*
 *  Dada (#321): захват микрофона на Mac Catalyst по явному устройству. Устройство — hal_capture.h.
 */
#import "modules/audio_device/hal_capture.h"

#if TARGET_OS_MACCATALYST

#import <Foundation/Foundation.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <cmath>
#include <utility>
#include <vector>

#include "rtc_base/logging.h"

namespace webrtc {

namespace {

constexpr AudioObjectPropertyAddress kDefaultInputAddress = {
    kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
constexpr AudioObjectPropertyAddress kDevicesAddress = {
    kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
constexpr AudioObjectPropertyAddress kAliveAddress = {
    kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
constexpr AudioObjectPropertyAddress kRateAddress = {
    kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

// Порция преобразования: больше BufferFrameSize любого микрофона; вызов длиннее режется на порции.
constexpr size_t kSliceFrames = 4096;
constexpr double kMinRate = 8000;
constexpr double kMaxRate = 384000;
// Ниже половины младшего разряда int16 — ровный ноль после преобразования: такой буфер не «звук».
constexpr float kVoicedFloor = 0.5f / 32768.0f;
// Конец поданной порции для AudioConverterFillComplexBuffer: не ошибка, преобразователь сохраняет состояние до следующей.
constexpr OSStatus kNoMoreInput = 0x44616461;
constexpr int64_t kTickMs = 100;
// Писателя нет, а поток не открылся или не дал кадров: новая попытка через столько.
constexpr int64_t kRetryMs = 1000;
// Новые пропуски циклов ввода — в публикацию не чаще этого: у перегруженного устройства они идут каждый цикл.
constexpr int64_t kDropsPublishMs = 1000;

struct ConverterInput {
  const float* data;
  UInt32 frames;
  bool given;
};

OSStatus ProvideInput(AudioConverterRef, UInt32* packets, AudioBufferList* data, AudioStreamPacketDescription**,
                      void* user) {
  ConverterInput* input = static_cast<ConverterInput*>(user);
  if (input->given || input->frames == 0) {
    *packets = 0;
    return kNoMoreInput;
  }
  data->mNumberBuffers = 1;
  data->mBuffers[0].mNumberChannels = 1;
  data->mBuffers[0].mDataByteSize = input->frames * static_cast<UInt32>(sizeof(float));
  data->mBuffers[0].mData = const_cast<float*>(input->data);
  *packets = input->frames;
  input->given = true;
  return noErr;
}

template <typename T>
bool Read(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, T* value) {
  const AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
  UInt32 size = static_cast<UInt32>(sizeof(T));
  return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, value) == noErr && size == sizeof(T);
}

std::string ReadString(AudioObjectID object, AudioObjectPropertySelector selector) {
  CFStringRef value = nullptr;
  if (!Read(object, selector, kAudioObjectPropertyScopeGlobal, &value) || value == nullptr) return std::string();
  NSString* text = (__bridge_transfer NSString*)value;
  const char* utf8 = text.UTF8String;
  return utf8 != nullptr ? std::string(utf8) : std::string();
}

std::vector<AudioObjectID> ReadIds(AudioObjectID object, AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope) {
  const AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(object, &address, 0, nullptr, &size) != noErr || size < sizeof(AudioObjectID)) {
    return {};
  }
  std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
  if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, ids.data()) != noErr) return {};
  ids.resize(size / sizeof(AudioObjectID));
  return ids;
}

AudioObjectID FirstInputStream(AudioObjectID device) {
  if (device == kAudioObjectUnknown) return kAudioObjectUnknown;
  const std::vector<AudioObjectID> streams = ReadIds(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
  return streams.empty() ? kAudioObjectUnknown : streams.front();
}

static_assert(CaptureFourCC("grup") == kAudioDeviceTransportTypeAggregate, "capture_target.h: transport 'grup'");
static_assert(CaptureFourCC("virt") == kAudioDeviceTransportTypeVirtual, "capture_target.h: transport 'virt'");
static_assert(CaptureFourCC("aagg") == kAudioAggregateDeviceClassID, "capture_target.h: class 'aagg'");

// Свойство UInt32 области global; nullopt — не прочиталось.
std::optional<UInt32> ReadU32(AudioObjectID object, AudioObjectPropertySelector selector) {
  UInt32 value = 0;
  if (!Read(object, selector, kAudioObjectPropertyScopeGlobal, &value)) return std::nullopt;
  return value;
}

// Устройства Core Audio по порядку kAudioHardwarePropertyDevices — те же чтения, по которым приложение строит список выбора
// (DadaAudioInput.inputs); толкует их capture_target.h (MakeCaptureDevice), решает по ним ChooseCaptureTarget.
std::vector<CaptureDevice> ReadDevices() {
  std::vector<CaptureDevice> devices;
  for (AudioObjectID id : ReadIds(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)) {
    devices.push_back(MakeCaptureDevice(id, ReadString(id, kAudioDevicePropertyDeviceUID),
                                        ReadIds(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).size(),
                                        ReadU32(id, kAudioDevicePropertyIsHidden), ReadU32(id, kAudioDevicePropertyTransportType),
                                        ReadU32(id, kAudioObjectPropertyClass)));
  }
  return devices;
}

bool IsBluetooth(AudioObjectID device) {
  UInt32 transport = 0;
  if (!Read(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)) return false;
  return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE;
}

// IOProc только на ввод, как AUHAL у Chrome (EnableIO = 0 на выходе): по умолчанию ему включены и выходные потоки устройства, и у
// устройства с одним AudioObject на ввод и вывод (USB-гарнитура, звуковая карта) HAL запускал бы ради нас его вывод.
void DisableOutput(AudioObjectID device, AudioDeviceIOProcID proc, const std::string& name) {
  const std::vector<AudioObjectID> outputs = ReadIds(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
  if (outputs.empty()) return;
  // В разметке — все потоки этого направления (AudioHardware.h); все mStreamIsOn — 0.
  const size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + outputs.size() * sizeof(UInt32);
  std::vector<UInt64> storage((size + sizeof(UInt64) - 1) / sizeof(UInt64), 0);
  AudioHardwareIOProcStreamUsage* usage = reinterpret_cast<AudioHardwareIOProcStreamUsage*>(storage.data());
  usage->mIOProc = reinterpret_cast<void*>(proc);
  usage->mNumberStreams = static_cast<UInt32>(outputs.size());
  const AudioObjectPropertyAddress address = {kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeOutput,
                                              kAudioObjectPropertyElementMain};
  const OSStatus status = AudioObjectSetPropertyData(device, &address, 0, nullptr, static_cast<UInt32>(size), usage);
  if (status != noErr) RTC_LOG(LS_WARNING) << "HalCapture: output streams of " << name << " stay on: " << status;
}

AudioStreamBasicDescription LinearPcm(double rate, AudioFormatFlags flags, UInt32 bits) {
  AudioStreamBasicDescription format = {};
  format.mSampleRate = rate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = flags | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
  format.mBitsPerChannel = bits;
  format.mChannelsPerFrame = 1;
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = bits / 8;
  format.mBytesPerPacket = bits / 8;
  return format;
}

// Преобразователь частоты устройства в 48 кГц моно int16. Частота вне пределов или отказ — *converter == nullptr.
OSStatus NewConverter(double device_rate, AudioConverterRef* converter) {
  *converter = nullptr;
  if (device_rate < kMinRate || device_rate > kMaxRate) return kAudio_ParamError;
  const AudioStreamBasicDescription source = LinearPcm(device_rate, kAudioFormatFlagIsFloat, 32);
  const AudioStreamBasicDescription target = LinearPcm(HalCapture::kSampleRate, kAudioFormatFlagIsSignedInteger, 16);
  const OSStatus status = AudioConverterNew(&source, &target, converter);
  if (status != noErr) *converter = nullptr;
  return status;
}

}  // namespace

const char* HalCapturePhaseName(HalCaptureState::Phase phase) {
  switch (phase) {
    case HalCaptureState::Phase::kIdle:
      return "idle";
    case HalCaptureState::Phase::kStarting:
      return "starting";
    case HalCaptureState::Phase::kRunning:
      return "running";
    case HalCaptureState::Phase::kSwitching:
      return "switching";
    case HalCaptureState::Phase::kFailed:
      return "failed";
  }
  return "idle";
}

NSDictionary* HalCaptureStateDictionary(const HalCaptureState& state) {
  NSString* (^text)(const std::string&) = ^NSString*(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()] ?: @"";
  };
  return @{
    @"uid" : text(state.uid),
    @"name" : text(state.name),
    @"rate" : @(state.rate),
    @"ch" : @(state.channels),
    @"mode" : state.explicit_device ? @"explicit" : @"default",
    @"requested" : text(state.requested),
    @"target" : text(state.target),
    @"phase" : @(HalCapturePhaseName(state.phase)),
    @"seq" : @(state.seq),
    @"switchMs" : @(state.switch_ms),
    @"reason" : text(state.reason),
    @"error" : text(state.error),
    @"drops" : @(state.drops),
    @"handoffs" : @(state.handoffs),
  };
}

struct HalCapture::Stream : std::enable_shared_from_this<HalCapture::Stream> {
  // Смена частоты для State (очередь управления, OnRateChanged).
  struct RateChange {
    double rate = 0;    // новая частота устройства; 0 — не прочиталась, преобразователь прежний
    std::string error;  // rate, converter:<код>; пусто — новый преобразователь встаёт
  };

  Stream() = default;
  Stream(const Stream&) = delete;
  Stream& operator=(const Stream&) = delete;
  ~Stream() {
    if (converter != nullptr) AudioConverterDispose(converter);
  }

  // Очередь захвата: подменить преобразователь — единственное, что смена частоты делает на этой очереди. nullptr — частота не
  // преобразуется: буферы потока в правило передачи не идут, для него поток молчит. Возвращает прежний: его освобождают вне
  // очереди захвата.
  AudioConverterRef Swap(AudioConverterRef fresh, double fresh_rate) {
    std::swap(converter, fresh);
    converter_rate = converter != nullptr ? fresh_rate : 0;
    return fresh;
  }

  // Очередь частоты. Читается то же, что слушаем, — частота устройства: id устройства постоянен, а поток ввода при его
  // перестройке может смениться. Частота другая — преобразователь собирается здесь, очередь захвата его только подменяет (её
  // синхронно ждут IO-потоки всех открытых устройств: ни запроса к coreaudiod, ни сборки там), прежний освобождается здесь же.
  // nullopt — частота та же.
  std::optional<RateChange> FollowRate(dispatch_queue_t capture, dispatch_queue_t follow_queue) {
    Float64 device_rate = 0;
    if (!Read(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &device_rate) ||
        device_rate <= 0) {
      RTC_LOG(LS_ERROR) << "HalCapture: " << name << " rate unreadable, converter stays at " << followed_rate << " Hz";
      return RateChange{0, "rate"};
    }
    if (device_rate == followed_rate) return std::nullopt;
    followed_rate = device_rate;
    AudioConverterRef fresh = nullptr;
    const OSStatus status = NewConverter(device_rate, &fresh);
    if (status != noErr) {
      RTC_LOG(LS_ERROR) << "HalCapture: " << name << " rate " << device_rate << " Hz, no converter: " << status;
    } else {
      RTC_LOG(LS_INFO) << "HalCapture: " << name << " rate " << device_rate << " Hz, converter rebuilt";
    }
    std::shared_ptr<Stream> keep = shared_from_this();
    dispatch_async(capture, ^{
      AudioConverterRef old = keep->Swap(fresh, device_rate);
      if (old != nullptr) {
        dispatch_async(follow_queue, ^{
          AudioConverterDispose(old);
        });
      }
    });
    return RateChange{device_rate, status != noErr ? "converter:" + std::to_string(status) : std::string()};
  }

  // Снятие — с глобальной очереди: оно ждёт идущий вызов блока, а тот идёт на очереди управления или частоты.
  void RemoveListeners(dispatch_queue_t control, dispatch_queue_t follow_queue) const {
    if (listener == nil && rate_listener == nil) return;
    const AudioObjectID object = device;
    AudioObjectPropertyListenerBlock alive_block = listener;
    AudioObjectPropertyListenerBlock rate_block = rate_listener;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      if (alive_block != nil) AudioObjectRemovePropertyListenerBlock(object, &kAliveAddress, control, alive_block);
      if (rate_block != nil) AudioObjectRemovePropertyListenerBlock(object, &kRateAddress, follow_queue, rate_block);
    });
  }

  uint64_t id = 0;
  AudioObjectID device = kAudioObjectUnknown;
  std::string uid;
  std::string name;
  double rate = 0;  // только очередь управления (State); захват считает по converter_rate
  UInt32 channels = 0;
  bool bluetooth = false;
  AudioDeviceIOProcID proc = nullptr;
  AudioObjectPropertyListenerBlock listener = nil;       // DeviceIsAlive, очередь управления
  AudioObjectPropertyListenerBlock rate_listener = nil;  // NominalSampleRate, очередь частоты
  // Только очередь частоты (в Open — до подписки): под какую частоту собран последний отданный захвату преобразователь.
  double followed_rate = 0;
  // Только очередь захвата.
  AudioConverterRef converter = nullptr;
  double converter_rate = 0;  // под какую частоту собран converter
  std::vector<float> mono;
  std::vector<int16_t> out;
  int convert_errors = 0;
  Float64 next_sample_time = -1;  // метка отсчётов, с которой ждём следующий вызов; -1 — вызовов ещё не было
  int drops = 0;
};

HalCapture::HalCapture(Deliver deliver, OnState on_state)
    : deliver_(std::move(deliver)), on_state_(std::move(on_state)), token_(std::make_shared<Token>()) {
  mach_timebase_info_data_t timebase = {0, 0};
  mach_timebase_info(&timebase);
  if (timebase.denom != 0) ticks_to_ns_ = static_cast<double>(timebase.numer) / static_cast<double>(timebase.denom);
  control_queue_ = dispatch_queue_create(
      "org.webrtc.hal_capture.control",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  capture_queue_ = dispatch_queue_create(
      "org.webrtc.hal_capture.capture",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
  rate_queue_ = dispatch_queue_create(
      "org.webrtc.hal_capture.rate",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
  token_->owner = this;
  std::shared_ptr<Token> token = token_;
  system_listener_ = ^(UInt32 count, const AudioObjectPropertyAddress* addresses) {
    HalCapture* owner = token->owner;
    for (UInt32 i = 0; owner != nullptr && i < count; ++i) {
      if (addresses[i].mSelector == kAudioHardwarePropertyDefaultInputDevice) owner->OnDefaultInputChanged();
      if (addresses[i].mSelector == kAudioHardwarePropertyDevices) owner->OnDevicesChanged();
    }
  };
  // Весь срок жизни, не только пока идёт захват: цель в снимке (target) актуальна и в простое.
  OSStatus status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefaultInputAddress, control_queue_,
                                                        system_listener_);
  if (status != noErr) RTC_LOG(LS_ERROR) << "HalCapture: default input listener failed: " << status;
  status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDevicesAddress, control_queue_, system_listener_);
  if (status != noErr) RTC_LOG(LS_ERROR) << "HalCapture: devices listener failed: " << status;
  Async([](HalCapture& self) {
    if (self.RefreshTarget()) self.PublishState();
  });
}

HalCapture::~HalCapture() {
  dispatch_sync(control_queue_, ^{
    StopOnControl();
    token_->owner = nullptr;
  });
  // Не с очереди управления: снятие ждёт идущий вызов слушателя, а он идёт на ней.
  AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDefaultInputAddress, control_queue_, system_listener_);
  AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDevicesAddress, control_queue_, system_listener_);
  // Блоки, поставленные до остановки, видят token->owner == nullptr или успевают отработать здесь.
  dispatch_sync(capture_queue_, ^{
  });
  dispatch_sync(control_queue_, ^{
  });
}

void HalCapture::Start() {
  delivering_.store(true, std::memory_order_release);
  Async([](HalCapture& self) { self.StartOnControl(); });
}

void HalCapture::Stop() {
  // Не ждать очередь управления: она может стоять в AudioDeviceStart (Brio ~0,4 с, холодная гарнитура дольше) или в цепочке
  // Retarget, а Stop зовёт рабочий поток WebRTC, за которым ждёт главный. Захват гасится флагом; пустой блок на очереди захвата
  // дожидается только идущего вызова — после него Deliver не зовётся. Потоки закрываются потом, на очереди управления.
  delivering_.store(false, std::memory_order_release);
  dispatch_sync(capture_queue_, ^{
  });
  Async([](HalCapture& self) { self.StopOnControl(); });
}

void HalCapture::SetDevice(std::optional<std::string> uid) {
  Async([uid](HalCapture& self) {
    self.explicit_ = uid.has_value() && !uid->empty();
    self.requested_uid_ = self.explicit_ ? *uid : std::string();
    self.error_.clear();
    self.follow_generation_ += 1;  // выдержка за системным входом больше не нужна
    RTC_LOG(LS_INFO) << "HalCapture: input " << (self.explicit_ ? self.requested_uid_ : std::string("default"));
    if (self.running_) {
      self.Retarget(false);
    } else {
      self.RefreshTarget();
      self.PublishState();
    }
  });
}

void HalCapture::SetMuted(bool muted) {
  muted_.store(muted, std::memory_order_relaxed);
}

HalCaptureState HalCapture::State() const {
  MutexLock lock(&state_mutex_);
  return state_;
}

void HalCapture::Async(std::function<void(HalCapture&)> work) {
  std::shared_ptr<Token> token = token_;
  dispatch_async(control_queue_, ^{
    if (token->owner != nullptr) work(*token->owner);
  });
}

void HalCapture::StartOnControl() {
  if (running_) return;
  running_ = true;
  drops_.store(0, std::memory_order_relaxed);
  handoffs_ = 0;
  tick_timer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, control_queue_);
  const uint64_t tick_ns = static_cast<uint64_t>(kTickMs) * NSEC_PER_MSEC;
  dispatch_source_set_timer(tick_timer_, dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(tick_ns)), tick_ns,
                            tick_ns / 10);
  std::shared_ptr<Token> token = token_;
  dispatch_source_set_event_handler(tick_timer_, ^{
    HalCapture* owner = token->owner;
    if (owner == nullptr) return;
    if (owner->drops_.load(std::memory_order_relaxed) != owner->published_drops_ &&
        owner->NowMs() - owner->published_ms_ >= kDropsPublishMs) {
      owner->PublishState();
    }
    dispatch_async(owner->capture_queue_, ^{
      const CaptureHandoff::Event event = owner->handoff_.OnTick(owner->NowMs());
      if (event.kind != CaptureHandoff::Event::Kind::kNone) owner->PostEvent(event);
    });
  });
  dispatch_resume(tick_timer_);
  Retarget(false);
}

void HalCapture::StopOnControl() {
  if (!running_) return;
  running_ = false;
  dispatch_sync(capture_queue_, ^{
    handoff_ = CaptureHandoff();
  });
  if (tick_timer_ != nullptr) {
    dispatch_source_cancel(tick_timer_);
    tick_timer_ = nullptr;
  }
  while (!streams_.empty()) Close(streams_.begin()->first);
  follow_generation_ += 1;
  // Снимок описывает только идущий захват: передача, её причина и ошибка не переходят в следующий звонок (журнал звонка пишет
  // снимок на входе, до старта захвата). Пропуски и число передач — итог этого захвата, их обнуляет старт.
  switch_ms_ = -1;
  reason_.clear();
  error_.clear();
  // Цель — по режиму, оставшемуся после звонка (явный держится, пока его не сменят): что откроет следующий старт.
  RefreshTarget();
  PublishState();
}

void HalCapture::Retarget(bool reopen_active) {
  if (!running_) return;
  const CaptureTarget chosen = Decide();
  if (explicit_ && chosen.uid != requested_uid_) {  // выбранного нет или его не показать: not_found, а если не с чего — no_device
    RTC_LOG(LS_WARNING) << "HalCapture: chosen input " << requested_uid_ << " not found, following the system input";
    explicit_ = false;
    requested_uid_.clear();
  }
  if (!chosen.error.empty()) error_ = chosen.error;
  target_uid_ = chosen.uid;
  const AudioObjectID target = chosen.id;
  if (target == kAudioObjectUnknown) {
    // Открытое не закрывается и пишет дальше (список не прочитался, перезапуск coreaudiod): цель — оно, как у RecoverIfSilent.
    const Stream* open = Find(candidate_id_);
    if (open == nullptr && active_id_ != stalled_id_) open = Find(active_id_);
    if (open != nullptr) target_uid_ = open->uid;
    RTC_LOG(LS_WARNING) << "HalCapture: no input device";
    PublishState();
    return;
  }
  const Stream* active = Find(active_id_);
  const Stream* candidate = Find(candidate_id_);
  if (candidate != nullptr && candidate->device == target) {
    PublishState();  // уже открывается
    return;
  }
  // Немой писатель (stalled_id_) — не «то, что пишет»: его устройство открывается заново рядом с ним.
  const bool reopen = reopen_active || (active_id_ != 0 && active_id_ == stalled_id_);
  if (active != nullptr && active->device == target && !reopen) {
    if (candidate != nullptr) Close(candidate_id_);  // вернулись к тому, что пишет
    PublishState();
    return;
  }
  if (candidate != nullptr) Close(candidate_id_);
  if (!Open(target)) RecoverIfSilent();
  PublishState();
}

CaptureTarget HalCapture::Decide() const {
  AudioObjectID system_default = kAudioObjectUnknown;
  if (!Read(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal,
            &system_default)) {
    system_default = kAudioObjectUnknown;
  }
  return ChooseCaptureTarget(ReadDevices(), system_default, explicit_, requested_uid_);
}

bool HalCapture::RefreshTarget() {
  std::string uid = Decide().uid;
  if (uid == target_uid_) return false;
  target_uid_ = std::move(uid);
  return true;
}

bool HalCapture::Open(AudioObjectID device) {
  std::shared_ptr<Stream> stream = std::make_shared<Stream>();
  stream->id = next_id_++;
  stream->device = device;
  stream->uid = ReadString(device, kAudioDevicePropertyDeviceUID);
  stream->name = ReadString(device, kAudioObjectPropertyName);
  stream->bluetooth = IsBluetooth(device);

  AudioStreamBasicDescription format = {};
  const AudioObjectID first = FirstInputStream(device);
  const bool readable = first != kAudioObjectUnknown &&
                        Read(first, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &format);
  if (!readable || format.mFormatID != kAudioFormatLinearPCM || (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
      format.mBitsPerChannel != 32 || format.mChannelsPerFrame == 0 || format.mSampleRate < kMinRate ||
      format.mSampleRate > kMaxRate) {
    RTC_LOG(LS_ERROR) << "HalCapture: unsupported input format of " << stream->name << ": " << format.mSampleRate << " Hz, "
                      << format.mChannelsPerFrame << " ch, " << format.mBitsPerChannel << " bit, flags "
                      << format.mFormatFlags;
    error_ = "format";
    return false;
  }
  stream->rate = format.mSampleRate;
  stream->channels = format.mChannelsPerFrame;

  // Блока потока и слушателя частоты ещё нет: поля захвата и очереди частоты пишутся отсюда.
  OSStatus status = NewConverter(stream->rate, &stream->converter);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "HalCapture: AudioConverterNew " << stream->rate << " Hz failed: " << status;
    error_ = "converter:" + std::to_string(status);
    return false;
  }
  stream->converter_rate = stream->rate;
  stream->followed_rate = stream->rate;
  stream->mono.resize(kSliceFrames);
  // Под самую низкую частоту: пересборка преобразователя на ходу не перевыделяет буфер на очереди захвата.
  stream->out.resize(static_cast<size_t>(std::ceil(static_cast<double>(kSliceFrames) * kSampleRate / kMinRate)) + 64);

  const uint64_t id = stream->id;
  std::shared_ptr<Stream> keep = stream;
  HalCapture* self = this;
  status = AudioDeviceCreateIOProcIDWithBlock(
      &stream->proc, device, capture_queue_,
      ^(const AudioTimeStamp*, const AudioBufferList* input, const AudioTimeStamp* input_time, AudioBufferList*,
        const AudioTimeStamp*) {
        self->OnInput(*keep, input, input_time);
      });
  if (status != noErr || stream->proc == nullptr) {
    RTC_LOG(LS_ERROR) << "HalCapture: AudioDeviceCreateIOProcIDWithBlock " << stream->name << " failed: " << status;
    error_ = "start:" + std::to_string(status);
    return false;
  }
  DisableOutput(device, stream->proc, stream->name);

  // Частота — на своей очереди (Stream::FollowRate): не на очереди управления — та может стоять в AudioDeviceStart другого
  // устройства, и не на очереди захвата — её синхронно ждут IO-потоки всех устройств, а здесь запрос к coreaudiod (он может ждать
  // запуска этого же устройства) и сборка преобразователя. Смена подменяет преобразователь до следующего буфера потока (у
  // писателя, у кандидата, во время запуска), без переоткрытия. Подписка до AudioDeviceStart, и сразу перечтение, дождавшись его:
  // смена до подписки слушателю не придёт, а подмена после перечтения встаёт в очередь захвата раньше первого буфера.
  // ponytail: буферы, пришедшие между сменой частоты в HAL и подменой преобразователя (уведомление, чтение частоты, сборка), ещё
  // идут через прежний (HAL в это время сам перезапускает ввод-вывод); частоты у буфера IOProc нет, а чтение формата на каждый
  // буфер — запрос к coreaudiod на очереди захвата. Понадобится закрыть и это окно — сверять частоту по меткам буфера
  // (mSampleTime к mHostTime) и не пускать в правило буфер, чья частота не сходится с преобразователем.
  std::shared_ptr<Token> token = token_;
  dispatch_queue_t control = control_queue_;
  dispatch_queue_t capture = capture_queue_;
  dispatch_queue_t follow_queue = rate_queue_;
  std::weak_ptr<Stream> weak = stream;
  AudioObjectPropertyListenerBlock follow = ^(UInt32, const AudioObjectPropertyAddress*) {
    const std::shared_ptr<Stream> followed = weak.lock();
    const std::optional<Stream::RateChange> change =
        followed != nullptr ? followed->FollowRate(capture, follow_queue) : std::nullopt;
    if (!change) return;
    const double rate = change->rate;
    const std::string error = change->error;
    dispatch_async(control, ^{
      if (token->owner != nullptr) token->owner->OnRateChanged(id, rate, error);
    });
  };
  stream->rate_listener = follow;
  AudioObjectAddPropertyListenerBlock(device, &kRateAddress, rate_queue_, follow);
  // Очередь частоты не ждёт очередь управления: ожидание отсюда без взаимной блокировки.
  dispatch_sync(rate_queue_, ^{
    follow(1, &kRateAddress);
  });

  // Кандидат известен правилу раньше первого буфера; снятый им прежний кандидат закрывается.
  const int64_t ceiling = stream->bluetooth ? CaptureHandoff::kCeilingBluetoothMs : CaptureHandoff::kCeilingWiredMs;
  dispatch_async(capture_queue_, ^{
    const uint64_t superseded = handoff_.Begin(id, NowMs(), ceiling);
    if (superseded != 0) Async([superseded](HalCapture& owner) { owner.Close(superseded); });
  });
  const int64_t started_ms = NowMs();
  status = AudioDeviceStart(device, stream->proc);
  const int64_t returned_ms = NowMs();
  const int64_t start_ms = returned_ms - started_ms;
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "HalCapture: AudioDeviceStart " << stream->name << " failed: " << status << " after "
                      << start_ms << " ms";
    AudioDeviceDestroyIOProcID(device, stream->proc);
    stream->proc = nullptr;
    stream->RemoveListeners(control_queue_, rate_queue_);
    dispatch_async(capture_queue_, ^{
      handoff_.Drop(id, NowMs());
    });
    error_ = "start:" + std::to_string(status);
    return false;
  }
  // Срок «нет кадров» — от возврата AudioDeviceStart, а не от открытия (capture_handoff.h).
  dispatch_async(capture_queue_, ^{
    handoff_.Started(id, returned_ms);
  });

  stream->listener = ^(UInt32 count, const AudioObjectPropertyAddress* addresses) {
    HalCapture* owner = token->owner;
    if (owner == nullptr) return;
    for (UInt32 i = 0; i < count; ++i) owner->OnDeviceChanged(id, addresses[i].mSelector);
  };
  AudioObjectAddPropertyListenerBlock(device, &kAliveAddress, control_queue_, stream->listener);

  streams_[id] = stream;
  candidate_id_ = id;
  RTC_LOG(LS_INFO) << "HalCapture: opened " << stream->name << " (" << stream->uid << "), " << stream->rate << " Hz x"
                   << stream->channels << (stream->bluetooth ? ", bluetooth" : "") << ", AudioDeviceStart " << start_ms
                   << " ms, stream " << id;
  return true;
}

void HalCapture::Close(uint64_t id) {
  auto it = streams_.find(id);
  if (it == streams_.end()) return;
  std::shared_ptr<Stream> stream = it->second;
  streams_.erase(it);
  if (id == active_id_) active_id_ = 0;
  if (id == candidate_id_) candidate_id_ = 0;
  // До остановки: буферы потока с этого места не пишутся, а право, если поток его только что принял, сразу возвращается
  // прежнему писателю (CaptureHandoff::Drop), не дожидаясь AudioDeviceStop.
  dispatch_async(capture_queue_, ^{
    handoff_.Drop(id, NowMs());
  });
  if (stream->proc != nullptr) {
    AudioDeviceStop(stream->device, stream->proc);
    AudioDeviceDestroyIOProcID(stream->device, stream->proc);
    stream->proc = nullptr;
  }
  stream->RemoveListeners(control_queue_, rate_queue_);
  RTC_LOG(LS_INFO) << "HalCapture: closed " << stream->name << ", stream " << id;
}

void HalCapture::HandleEvent(const CaptureHandoff::Event& event) {
  if (!running_) return;
  if (event.kind == CaptureHandoff::Event::Kind::kSwitched) {
    const Stream* writer = Find(event.stream);
    if (writer == nullptr) {
      // Право ушло к потоку, который управление уже закрыло (новый выбор пришёл во время его открытия, или он пропал): захват
      // вернул право прежнему писателю, если тот ещё открыт (CaptureHandoff::Drop), — его не закрывать; выбрать заново.
      active_id_ = Find(event.retired) != nullptr ? event.retired : 0;
      Retarget(false);
      return;
    }
    if (event.retired != 0) Close(event.retired);
    active_id_ = event.stream;
    handoffs_ += 1;
    if (candidate_id_ == event.stream) candidate_id_ = 0;
    switch_ms_ = event.wait_ms;
    reason_ = CaptureHandoff::ReasonName(event.reason);
    error_.clear();  // устройство пишет: прежняя ошибка уже не про то, что сейчас
    if (event.reason == CaptureHandoff::Reason::kCeiling) {
      RTC_LOG(LS_WARNING) << "HalCapture: no sound from " << writer->name << " in " << event.wait_ms
                          << " ms, it writes anyway";
    }
    RTC_LOG(LS_INFO) << "HalCapture: " << writer->name << " writes (" << reason_ << ", " << event.wait_ms << " ms)";
    PublishState();
    return;
  }
  if (event.kind == CaptureHandoff::Event::Kind::kCancelled) {
    const Stream* stream = Find(event.stream);
    // Уже закрыт управлением (новый выбор, пропажа, остановка звонка — событие стояло в очереди за ней): «нет кадров» не про него,
    // а следующий шаг управление уже сделало.
    if (stream == nullptr) return;
    RTC_LOG(LS_WARNING) << "HalCapture: no frames from " << stream->name << " in " << event.wait_ms
                        << " ms, staying on the previous input";
    Close(event.stream);
    error_ = "no_frames";
    RecoverIfSilent();
    PublishState();
    return;
  }
  if (event.kind == CaptureHandoff::Event::Kind::kActiveDead) {
    const Stream* writer = Find(event.stream);
    if (writer == nullptr || event.stream != active_id_) return;  // уже сменился или снят
    RTC_LOG(LS_WARNING) << "HalCapture: no buffers from " << writer->name << " for " << event.wait_ms
                        << " ms without DeviceIsAlive, reopening";
    stalled_id_ = event.stream;
    error_ = "stalled";
    Retarget(true);
  }
}

void HalCapture::RecoverIfSilent() {
  if (!running_ || Find(candidate_id_) != nullptr) return;
  // Цель (target_uid_) Retarget поставил до Open; открыть её не вышло — снимок, который опубликуют следом, называет то, что пишет,
  // или то, что откроет повтор, а не отказавшее устройство.
  const Stream* writer = Find(active_id_);
  if (writer != nullptr && active_id_ != stalled_id_) {
    target_uid_ = writer->uid;
    return;
  }
  if (explicit_) {
    RTC_LOG(LS_WARNING) << "HalCapture: chosen input " << requested_uid_ << " does not capture, following the system input";
    explicit_ = false;
    requested_uid_.clear();
  }
  RefreshTarget();
  // ponytail: повтор раз в секунду без предела — у микрофона, который не открывается никогда, это строка журнала в секунду;
  // понадобится предел — счётчик попыток здесь.
  RetargetAfter(kRetryMs);
}

void HalCapture::RetargetAfter(int64_t delay_ms) {
  const uint64_t generation = ++follow_generation_;
  std::shared_ptr<Token> token = token_;
  const int64_t delay_ns = delay_ms * static_cast<int64_t>(NSEC_PER_MSEC);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay_ns), control_queue_, ^{
    HalCapture* owner = token->owner;
    if (owner == nullptr || generation != owner->follow_generation_ || !owner->running_) return;
    owner->Retarget(false);
  });
}

void HalCapture::OnDefaultInputChanged() {
  if (!running_) {
    if (RefreshTarget()) PublishState();
    return;
  }
  if (explicit_) return;  // явный выбор держится
  RTC_LOG(LS_INFO) << "HalCapture: system input changed, following in " << kDefaultFollowMs << " ms";
  RetargetAfter(kDefaultFollowMs);
}

void HalCapture::OnDevicesChanged() {
  if (!running_) {
    if (RefreshTarget()) PublishState();
    return;
  }
  // Писать не с чего (no_device), а подключили микрофон, не ставший входом системы, — выбрать заново; кто-то пишет или
  // открывается — список его не касается (пропажу пишущего ведёт DeviceIsAlive).
  const bool writing = Find(active_id_) != nullptr && active_id_ != stalled_id_;
  if (writing || Find(candidate_id_) != nullptr) return;
  RetargetAfter(kDefaultFollowMs);
}

void HalCapture::OnDeviceChanged(uint64_t id, AudioObjectPropertySelector selector) {
  const Stream* stream = Find(id);
  if (stream == nullptr || selector != kAudioDevicePropertyDeviceIsAlive) return;
  UInt32 alive = 0;
  if (Read(stream->device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, &alive) && alive != 0) {
    return;
  }
  const bool chosen = explicit_ && stream->uid == requested_uid_;
  RTC_LOG(LS_WARNING) << "HalCapture: " << stream->name << " is gone";
  Close(id);
  if (chosen) {
    explicit_ = false;
    requested_uid_.clear();
    error_ = "gone";
  }
  Retarget(false);
}

void HalCapture::OnRateChanged(uint64_t id, double rate, const std::string& error) {
  Stream* stream = Find(id);
  if (stream == nullptr) return;
  if (rate > 0) stream->rate = rate;
  if (!error.empty()) error_ = error;
  if (!error.empty() || id == active_id_) PublishState();
}

void HalCapture::PublishState() {
  const Stream* active = Find(active_id_);
  HalCaptureState::Phase phase = HalCaptureState::Phase::kIdle;
  if (running_ && active != nullptr) {
    phase = candidate_id_ != 0 ? HalCaptureState::Phase::kSwitching : HalCaptureState::Phase::kRunning;
  } else if (running_) {
    phase = candidate_id_ != 0 ? HalCaptureState::Phase::kStarting : HalCaptureState::Phase::kFailed;
  }
  HalCaptureState snapshot;
  {
    MutexLock lock(&state_mutex_);
    state_.uid = active != nullptr ? active->uid : std::string();
    state_.name = active != nullptr ? active->name : std::string();
    state_.rate = active != nullptr ? active->rate : 0;
    state_.channels = active != nullptr ? static_cast<int>(active->channels) : 0;
    state_.explicit_device = explicit_;
    state_.requested = requested_uid_;  // пусто, пока явного выбора нет
    state_.target = target_uid_;
    state_.phase = phase;
    state_.switch_ms = switch_ms_;
    state_.reason = reason_;
    state_.error = error_;
    state_.drops = drops_.load(std::memory_order_relaxed);
    state_.handoffs = handoffs_;
    state_.seq += 1;
    snapshot = state_;
  }
  published_drops_ = snapshot.drops;
  published_ms_ = NowMs();
  if (on_state_) on_state_(snapshot);
}

HalCapture::Stream* HalCapture::Find(uint64_t id) const {
  if (id == 0) return nullptr;
  auto it = streams_.find(id);
  return it != streams_.end() ? it->second.get() : nullptr;
}

void HalCapture::OnInput(Stream& stream, const AudioBufferList* input, const AudioTimeStamp* input_time) {
  // Частота устройства не преобразуется (NewConverter, Stream::Swap): в звонок не идёт ничего, для правила передачи поток молчит.
  if (stream.converter == nullptr) return;
  if (input == nullptr || input->mNumberBuffers == 0) return;
  const AudioBuffer& buffer = input->mBuffers[0];
  const size_t stride = buffer.mNumberChannels;
  if (buffer.mData == nullptr || stride == 0) return;
  const size_t frames = buffer.mDataByteSize / (sizeof(float) * stride);
  if (frames == 0) return;
  const float* samples = static_cast<const float*>(buffer.mData);

  // Пропуск цикла ввода: метка отсчётов ушла дальше ожидаемой больше чем на полбуфера — IO-поток устройства не успел (все IOProc
  // идут через одну очередь захвата, и на стыке передачи поток одного устройства ждёт блок другого).
  Float64 skipped = 0;
  if (input_time != nullptr && (input_time->mFlags & kAudioTimeStampSampleTimeValid) != 0) {
    const Float64 frames_f = static_cast<Float64>(frames);
    if (stream.next_sample_time >= 0 && input_time->mSampleTime > stream.next_sample_time + frames_f / 2) {
      skipped = input_time->mSampleTime - stream.next_sample_time;
    }
    stream.next_sample_time = input_time->mSampleTime + frames_f;
  }

  // Первый канал первого потока: многоканальный вход даёт свой первый микрофон.
  bool voiced = false;
  for (size_t i = 0; i < frames && !voiced; ++i) {
    const float value = samples[i * stride];
    voiced = std::isfinite(value) && std::fabs(value) >= kVoicedFloor;
  }
  const CaptureHandoff::Verdict verdict = handoff_.OnBuffer(stream.id, NowMs(), voiced);
  const bool write = verdict.write && delivering_.load(std::memory_order_acquire);
  if (skipped > 0) {
    // В счётчик — дыры в том, что уходит в звонок; пропуск потока, который не пишет (разгон гарнитуры), — только в журнал.
    if (write) drops_.fetch_add(1, std::memory_order_relaxed);
    if (stream.drops++ == 0) {
      RTC_LOG(LS_WARNING) << "HalCapture: " << stream.name << " skipped " << skipped << " frames (first drop of stream "
                          << stream.id << (write ? ", writing" : ", not writing") << ")";
    }
  }
  const bool muted = muted_.load(std::memory_order_relaxed);
  const bool stamped = input_time != nullptr && (input_time->mFlags & kAudioTimeStampHostTimeValid) != 0;
  const int64_t stamp_ns = HostTimeNs(stamped ? input_time->mHostTime : mach_absolute_time());

  // Преобразуется каждый буфер, и тот, что не пишется: состояние преобразователя частоты идёт без разрывов.
  for (size_t offset = 0; offset < frames; offset += kSliceFrames) {
    const size_t count = std::min(kSliceFrames, frames - offset);
    for (size_t i = 0; i < count; ++i) {
      // Нечисло и перегруз отравляют фильтр преобразователя навсегда — чистим до него.
      const float value = samples[(offset + i) * stride];
      stream.mono[i] = std::isfinite(value) ? std::clamp(value, -1.0f, 1.0f) : 0.0f;
    }
    ConverterInput source = {stream.mono.data(), static_cast<UInt32>(count), false};
    AudioBufferList output;
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = 1;
    output.mBuffers[0].mDataByteSize = static_cast<UInt32>(stream.out.size() * sizeof(int16_t));
    output.mBuffers[0].mData = stream.out.data();
    UInt32 produced = static_cast<UInt32>(stream.out.size());
    const OSStatus status =
        AudioConverterFillComplexBuffer(stream.converter, &ProvideInput, &source, &produced, &output, nullptr);
    if (status != noErr && status != kNoMoreInput) {
      if (stream.convert_errors++ == 0) {
        RTC_LOG(LS_ERROR) << "HalCapture: AudioConverterFillComplexBuffer " << stream.name << ": " << status;
      }
      continue;
    }
    if (!write || produced == 0) continue;
    if (muted) std::fill_n(stream.out.data(), produced, int16_t{0});
    const int64_t offset_ns = static_cast<int64_t>(static_cast<double>(offset) * 1e9 / stream.converter_rate);
    deliver_(stream.out.data(), produced, stamp_ns + offset_ns);
  }
  if (verdict.event.kind != CaptureHandoff::Event::Kind::kNone) PostEvent(verdict.event);
}

void HalCapture::PostEvent(const CaptureHandoff::Event& event) {
  Async([event](HalCapture& self) { self.HandleEvent(event); });
}

int64_t HalCapture::NowMs() const {
  return static_cast<int64_t>(static_cast<double>(mach_absolute_time()) * ticks_to_ns_ / 1e6);
}

int64_t HalCapture::HostTimeNs(uint64_t host_time) const {
  return static_cast<int64_t>(static_cast<double>(host_time) * ticks_to_ns_);
}

}  // namespace webrtc

#endif  // TARGET_OS_MACCATALYST
