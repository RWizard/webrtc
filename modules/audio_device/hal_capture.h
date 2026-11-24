/*
 *  Dada (#321): захват микрофона на Mac Catalyst по явному устройству — как в Chrome (media/audio/apple/
 *  audio_low_latency_input.cc): каждый микрофон открывается своим блоком только на ввод (выходные потоки устройства ему
 *  выключены, kAudioDevicePropertyIOProcStreamUsage), системный вход и вывод не трогаются.
 *
 *  Зачем. AVAudioEngine в Catalyst выбирать устройство ввода не умеет: смена микрофона шла сменой системного входа, движок
 *  ждал уведомления системы (при уходе с гарнитуры Bluetooth до 8 с) и пересобирался целиком вместе с выводом — 7–10 с тишины,
 *  а остановки ввода-вывода на работающей гарнитуре гоняли модуль Bluetooth по кругу перестроек (икание).
 *
 *  Как. IOProc по AudioDeviceID на общей последовательной очереди захвата; формат читается у устройства и не пишется
 *  (ни NominalSampleRate, ни BufferFrameSize — правило Chrome); свой AudioConverter даёт постоянные 48 кГц моно int16, так что
 *  APM, эхоподавление и шумодав смены частоты не видят; метка буфера — mHostTime. Частота устройства сменилась на ходу или во
 *  время его запуска — по уведомлению HAL новый преобразователь собирается на очереди частоты, а очередь захвата только подменяет
 *  его до следующего буфера этого потока, у писателя и у кандидата, без переоткрытия. Смена устройства: новый поток запускается
 *  рядом со старым, право записи переходит по правилу CaptureHandoff (capture_handoff.h) — без паузы и без двух писателей.
 *  Режим «по умолчанию» идёт за системным входом с выдержкой 500 мс той же передачей; явный выбор держится; пропал выбранный —
 *  переход на «по умолчанию» с причиной. Писатель замолчал без вести (нет буферов 1,5 с, а DeviceIsAlive не пришёл: перезапуск
 *  coreaudiod, зависшая гарнитура) — устройство ищется заново и открывается рядом с немым писателем, ошибка «stalled». Писателя
 *  нет (первый поток звонка, после заглушения перезапуском, пропал пишущий) или он немой, а поток не открылся или не дал
 *  кадров — явный выбор тоже уступает системному входу, и через 1 с новая попытка: микрофон не молчит до конца звонка. Какое
 *  устройство пишет и в каком формате — источник правды здесь (State, OnState).
 *
 *  С какого устройства писать, решает capture_target.h: только с того, что приложение показывает в списке выбора (вход системы
 *  виртуальный, составной, скрытый — «по умолчанию» пишет первое показываемое). Решение в снимке (target) актуально и в простое:
 *  слушатели входа системы и списка устройств стоят весь срок жизни HalCapture; в простое они только пересчитывают цель.
 *
 *  Потоки. Управление (открытие, AudioDeviceStart/Stop — у Brio до ~0,4 с, слушатели Core Audio, выдержки) — своя очередь
 *  управления; IOProc всех потоков — одна очередь захвата: её синхронно ждут IO-потоки всех открытых устройств, поэтому на ней
 *  нет ни запросов к HAL, ни сборки преобразователя — только его подмена; слушатель частоты (чтение частоты устройства, сборка
 *  преобразователя) — своя очередь частоты. Ни одна из них не ждёт поток WebRTC, а поток WebRTC не ждёт очередь управления
 *  (Stop ждёт только идущий вызов захвата). Очередь захвата не ждёт никого. Слушатели снимаются отложенно с
 *  глобальной очереди: снятие блока со своей же очереди может ждать сам себя.
 */
#ifndef MODULES_AUDIO_DEVICE_HAL_CAPTURE_H_
#define MODULES_AUDIO_DEVICE_HAL_CAPTURE_H_

#include <TargetConditionals.h>

#if TARGET_OS_MACCATALYST

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>

#include "modules/audio_device/capture_handoff.h"
#include "modules/audio_device/capture_target.h"
#include "rtc_base/synchronization/mutex.h"
#include "rtc_base/thread_annotations.h"

#ifdef __OBJC__
@class NSDictionary;
#endif

namespace webrtc {

// Какой микрофон пишет в WebRTC и в каком формате.
struct HalCaptureState {
  enum class Phase { kIdle, kStarting, kRunning, kSwitching, kFailed };
  std::string uid;  // пишущее устройство; пусто — никто не пишет
  std::string name;
  double rate = 0;   // его частота, Гц (в WebRTC всегда 48 кГц моно)
  int channels = 0;  // каналов у его первого потока ввода
  bool explicit_device = false;  // явный выбор; false — идёт за системным входом
  std::string requested;         // uid явного выбора человека, пока он держится; пусто — «по умолчанию»
  // Куда идёт захват (capture_target.h): идёт — пишущее или открываемое устройство (открыть не вышло — пишущее, а если никто не
  // пишет, то, что откроет повтор; писать не с чего, а поток открыт — открываемое, иначе пишущее); стоит — что откроет старт по
  // текущему режиму. Пусто — писать не с чего и ничего не открыто.
  std::string target;
  Phase phase = Phase::kIdle;  // idle — не пишет; starting — первый поток открыт; switching — новый рядом со старым
  uint64_t seq = 0;            // растёт с каждой публикацией
  int64_t switch_ms = -1;      // последняя передача этого захвата: от открытия нового до права записи
  std::string reason;          // её причина: first, voiced, ceiling, stalled
  // Последняя ошибка: gone, not_found, no_device, no_frames, stalled, format, rate (частота устройства не прочиталась),
  // start:<код>, converter:<код>. Успешная передача права её снимает. Остановка захвата снимает её вместе с передачей и
  // причиной: снимок не несёт прошлый звонок в следующий.
  std::string error;
  uint64_t drops = 0;  // пропуски циклов ввода пишущего потока с Start: метка отсчётов прыгнула дальше половины буфера
  // Передачи права записи в этом захвате, включая первую: +1 на каждую передачу действующему потоку (kSwitched с писателем;
  // право, ушедшее к уже закрытому потоку, — не передача). Обнуляет Start, остановка сохраняет итог. Отличает две передачи тому
  // же устройству с теми же switch_ms и reason.
  uint64_t handoffs = 0;  // в каждом снимке
};

const char* HalCapturePhaseName(HalCaptureState::Phase phase);

#ifdef __OBJC__
// Ключи: uid, name, rate, ch, mode (default | explicit), requested, target, phase, seq, switchMs, reason, error, drops, handoffs.
NSDictionary* HalCaptureStateDictionary(const HalCaptureState& state);
#endif

class HalCapture {
 public:
  static constexpr int kSampleRate = 48000;
  static constexpr int64_t kDefaultFollowMs = 500;

  // Очередь захвата: 10 мс и любые другие порции 48 кГц моно с меткой захвата первого отсчёта.
  using Deliver = std::function<void(const int16_t* samples, size_t frames, int64_t capture_time_ns)>;
  // Очередь управления: каждое изменение состояния. Не блокировать и не звать отсюда HalCapture синхронно.
  using OnState = std::function<void(const HalCaptureState& state)>;

  HalCapture(Deliver deliver, OnState on_state);
  ~HalCapture();
  HalCapture(const HalCapture&) = delete;
  HalCapture& operator=(const HalCapture&) = delete;

  // Любой поток, не ждёт устройства.
  void Start();
  // Любой поток кроме очередей HalCapture. После возврата Deliver больше не зовётся; ждёт только идущий вызов захвата, не
  // устройство: потоки закрываются потом на очереди управления.
  void Stop();
  // nullopt или пустая строка — «по умолчанию». Любой поток, не ждёт.
  void SetDevice(std::optional<std::string> uid);
  // Писать нули вместо звука (заглушение микшером входа). Любой поток.
  void SetMuted(bool muted);
  HalCaptureState State() const;

 private:
  struct Stream;
  struct Token {
    HalCapture* owner = nullptr;  // читается и пишется только на очереди управления
  };

  // Очередь управления.
  void Async(std::function<void(HalCapture&)> work);
  void StartOnControl();
  void StopOnControl();
  void Retarget(bool reopen_active);
  // Решение capture_target.h по нынешним устройствам Core Audio и режиму; выбор человека не снимает.
  CaptureTarget Decide() const;
  // Простой: цель по текущему режиму — в target_uid_; true — сменилась.
  bool RefreshTarget();
  bool Open(AudioObjectID device);
  void Close(uint64_t id);
  void HandleEvent(const CaptureHandoff::Event& event);
  // Открыть цель не вышло (отказ Open, отмена no_frames). Кандидат есть — ничего; пишет прежний — цель он; иначе микрофон молчит:
  // явный выбор уступает системному входу, цель — что откроет повтор через 1 с. Снимок публикует зовущий.
  void RecoverIfSilent();
  // Retarget через delay_ms; новый повод (выбор, системный вход, повтор, остановка) снимает отложенный.
  void RetargetAfter(int64_t delay_ms);
  void OnDefaultInputChanged();
  void OnDevicesChanged();
  void OnDeviceChanged(uint64_t id, AudioObjectPropertySelector selector);
  // Частоту потока уже сменила очередь частоты (Stream::FollowRate): здесь — в State; rate 0 — не прочиталась, error — rate или
  // converter:<код>.
  void OnRateChanged(uint64_t id, double rate, const std::string& error);
  void PublishState();
  Stream* Find(uint64_t id) const;

  // Очередь захвата.
  void OnInput(Stream& stream, const AudioBufferList* input, const AudioTimeStamp* input_time);
  void PostEvent(const CaptureHandoff::Event& event);

  int64_t NowMs() const;
  int64_t HostTimeNs(uint64_t host_time) const;

  const Deliver deliver_;
  const OnState on_state_;
  double ticks_to_ns_ = 1;
  dispatch_queue_t control_queue_;
  dispatch_queue_t capture_queue_;
  dispatch_queue_t rate_queue_;  // слушатель частоты устройств: запросы к HAL и сборка преобразователя вне очереди захвата
  std::shared_ptr<Token> token_;
  AudioObjectPropertyListenerBlock system_listener_;  // вход системы и список устройств, весь срок жизни

  // Только очередь управления.
  bool running_ = false;
  bool explicit_ = false;
  std::string requested_uid_;
  std::string target_uid_;
  uint64_t next_id_ = 1;
  uint64_t follow_generation_ = 0;  // отложенный Retarget (RetargetAfter): устаревает с каждым новым поводом
  std::map<uint64_t, std::shared_ptr<Stream>> streams_;
  uint64_t active_id_ = 0;
  uint64_t candidate_id_ = 0;
  uint64_t stalled_id_ = 0;  // писатель, замолчавший без вести (kActiveDead): не считается пишущим, его устройство переоткрывается
  int64_t switch_ms_ = -1;
  uint64_t handoffs_ = 0;  // HalCaptureState::handoffs
  std::string reason_;
  std::string error_;
  dispatch_source_t tick_timer_ = nullptr;
  uint64_t published_drops_ = 0;
  int64_t published_ms_ = 0;

  // Только очередь захвата.
  CaptureHandoff handoff_;

  // Пишет поток WebRTC (Start/Stop), читает очередь захвата.
  std::atomic<bool> delivering_{false};
  // Пишет очередь захвата, читает очередь управления.
  std::atomic<uint64_t> drops_{0};

  std::atomic<bool> muted_{false};

  mutable Mutex state_mutex_;
  HalCaptureState state_ RTC_GUARDED_BY(state_mutex_);
};

}  // namespace webrtc

#endif  // TARGET_OS_MACCATALYST

#endif  // MODULES_AUDIO_DEVICE_HAL_CAPTURE_H_
