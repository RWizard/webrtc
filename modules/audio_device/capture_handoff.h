/*
 *  Dada (#321): смена микрофона без паузы и без двух писателей — передача права записи между потоками захвата (как в Chrome).
 *
 *  Каждый микрофон открывается своим потоком HAL по явному устройству (hal_capture.mm). Новый поток запускается рядом со
 *  старым; старый продолжает писать в WebRTC, пока новый не готов. Готовность — первый НЕНУЛЕВОЙ буфер: гарнитура Bluetooth
 *  из холода первые ~0,7 с отдаёт ровные нули (замер шага 0, 23.11), и переход на них дал бы ту же паузу. Ждать звука вечно
 *  нельзя (микрофон закрытой крышки отдаёт нули всегда) — по потолку право переходит всё равно, с причиной «потолок». Потолок
 *  считается от первого буфера нового, а не от открытия: AudioDeviceStart держит поток управления (Brio ~0,4 с, у холодной
 *  гарнитуры не замерено), и потолок от открытия съел бы разгон нулями и передал бы право на них.
 *  Право переходит на границе буфера старого: он пишет свой буфер последним, дальше пишет новый. Буфер нового, начавшийся не
 *  позже конца этого буфера старого, закрывает стык без дыры (перекрытие — меньше буфера нового).
 *
 *  Старый замолчал (нет буферов дольше StalledAfterMs: пропуск гарнитуры, устройство пропало) — передача принудительная на
 *  ближайшем буфере нового, даже нулевом: от старого всё равно ничего нет. Порог — утроенный наибольший интервал самого старого за
 *  последние 1–2 с, но не меньше kStalledMs: у узкополосной гарнитуры буфер до 64 мс и дрожание Bluetooth в десятки мс, и
 *  постоянный порог принимал её обычный интервал за остановку и отдавал право нулям разгона нового. Долгий пропуск старого
 *  тоже поднимает порог: раз старый так молчит и оживает, такое молчание — ещё не остановка. Новый не дал ни одного буфера за
 *  kNoFramesMs после возврата AudioDeviceStart (Started) — отмена, старый остаётся. Новый выбор посреди передачи снимает
 *  прежнего кандидата.
 *
 *  Писатель замолчал без вести (перезапуск coreaudiod, зависшая гарнитура: DeviceIsAlive не приходит), а кандидата нет —
 *  через kDeadMs тишины одно событие kActiveDead на писателя: захват ищет устройство заново, и первый буфер нового потока
 *  берёт право как «старый замолчал». Без него захват стоял бы до конца звонка.
 *
 *  О передаче поток управления узнаёт событием, а оно может стоять в его очереди за новым выбором. Если управление успело
 *  закрыть нового писателя как кандидата, а прежний ещё открыт и был жив на передаче, право возвращается прежнему (Drop):
 *  звонок не остаётся без писателя до первого буфера следующего потока.
 *
 *  Буферы всех потоков приходят на одну последовательную очередь захвата, и правило решает по каждому, пишет ли он: писатель
 *  в любой момент один. Время — монотонные мс прихода вызова. Чистый C++ без зависимостей WebRTC: копия файла с проверкой лежит
 *  в репозитории Dada (apps/mobile/plugins/mac-webrtc/fork/audio_device, tests/c/CaptureHandoffCheck.cpp).
 */
#ifndef MODULES_AUDIO_DEVICE_CAPTURE_HANDOFF_H_
#define MODULES_AUDIO_DEVICE_CAPTURE_HANDOFF_H_

#include <algorithm>
#include <cstdint>

namespace webrtc {

class CaptureHandoff {
 public:
  // Тишина старого дольше StalledAfterMs — он встал: передача без ожидания его границы. Порог — его наибольший интервал за
  // последние 1–2 с (окна по kCadenceWindowMs), умноженный на kStalledIntervals, но не меньше kStalledMs.
  static constexpr int64_t kStalledMs = 100;
  static constexpr int64_t kStalledIntervals = 3;
  static constexpr int64_t kCadenceWindowMs = 1000;
  // Писатель без буферов дольше этого при отсутствии кандидата — замолчал без вести (kActiveDead).
  static constexpr int64_t kDeadMs = 1500;
  // Новый поток без единого буфера дольше этого после возврата AudioDeviceStart — отмена.
  static constexpr int64_t kNoFramesMs = 3000;
  // Потолок ожидания звука от первого буфера нового: гарнитура Bluetooth разгоняется нулями ~0,7 с, проводной звучит сразу.
  static constexpr int64_t kCeilingBluetoothMs = 1500;
  static constexpr int64_t kCeilingWiredMs = 1000;

  enum class Reason { kNone, kFirst, kVoiced, kCeiling, kStalled, kNoFrames };

  struct Event {
    enum class Kind { kNone, kSwitched, kCancelled, kActiveDead };
    Kind kind = Kind::kNone;
    uint64_t stream = 0;   // kSwitched — новый писатель; kCancelled — снятый кандидат; kActiveDead — замолчавший писатель
    uint64_t retired = 0;  // kSwitched — прежний писатель, его поток закрыть (0 — его не было)
    Reason reason = Reason::kNone;
    int64_t wait_ms = 0;   // от открытия нового до события; kActiveDead — сколько писатель молчит
  };

  struct Verdict {
    bool write = false;  // писать этот буфер в WebRTC
    Event event;
  };

  static const char* ReasonName(Reason reason) {
    switch (reason) {
      case Reason::kNone:
        return "";
      case Reason::kFirst:
        return "first";
      case Reason::kVoiced:
        return "voiced";
      case Reason::kCeiling:
        return "ceiling";
      case Reason::kStalled:
        return "stalled";
      case Reason::kNoFrames:
        return "no_frames";
    }
    return "";
  }

  // Открыт новый поток (id не 0 и не повторяется). Возвращает снятого прежнего кандидата (0 — его не было): его закрыть.
  uint64_t Begin(uint64_t stream, int64_t now_ms, int64_t ceiling_ms) {
    const uint64_t superseded = candidate_;
    candidate_ = stream;
    begin_ms_ = now_ms;
    ceiling_ms_ = ceiling_ms;
    started_ = false;
    started_ms_ = 0;
    has_frames_ = false;
    first_frame_ms_ = 0;
    ready_ = Reason::kNone;
    return superseded;
  }

  // AudioDeviceStart нового вернулся: отсюда идёт срок «нет кадров». До него поток управления занят открытием, и отмена по
  // часам открытия сняла бы устройство, которое ещё запускается.
  void Started(uint64_t stream, int64_t now_ms) {
    if (stream != candidate_ || started_) return;
    started_ = true;
    started_ms_ = now_ms;
  }

  // Поток закрыт или устройство пропало. Пропавший писатель считается замолчавшим: кандидат примет право первым же буфером.
  // Снят писатель, только что принявший право, а прежний ещё открыт и жив (управление узнаёт о передаче событием позже и закрыло
  // нового как кандидата: новый выбор пришёл во время его открытия, или он пропал) — право сразу возвращается прежнему, звонок не
  // ждёт первого буфера следующего потока.
  void Drop(uint64_t stream, int64_t now_ms) {
    if (stream == 0) return;
    if (stream == candidate_) candidate_ = 0;
    if (stream == retired_) retired_ = 0;
    if (stream != active_) return;
    if (retired_ == 0) {
      active_alive_ = false;
      return;
    }
    Become(retired_, now_ms);
    retired_ = 0;
  }

  Verdict OnBuffer(uint64_t stream, int64_t now_ms, bool voiced) {
    Verdict verdict;
    if (stream == 0) return verdict;
    if (stream == candidate_) {
      if (!has_frames_) {
        has_frames_ = true;
        first_frame_ms_ = now_ms;
      }
      if (ready_ == Reason::kNone && voiced) ready_ = Reason::kVoiced;
      CheckCeiling(now_ms);
      if (active_ == 0 || Stalled(now_ms)) {
        verdict.event = Switch(now_ms, active_ == 0 ? Reason::kFirst : Reason::kStalled);
        verdict.write = true;
      }
      return verdict;
    }
    if (stream != active_) return verdict;  // ушедший поток или чужой
    NoteWriterBuffer(now_ms);
    verdict.write = true;
    if (candidate_ == 0) return verdict;
    verdict.event = Settle(now_ms);
    if (verdict.event.kind == Event::Kind::kNone && ready_ != Reason::kNone) {
      verdict.event = Switch(now_ms, ready_);  // граница буфера старого: этот буфер — его последний
    }
    return verdict;
  }

  // Раз в ~100 мс: решения, когда буферов нет ни от кого (новый без кадров, оба встали, писатель замолчал без вести).
  Event OnTick(int64_t now_ms) {
    if (candidate_ == 0) return CheckDead(now_ms);
    const Event settled = Settle(now_ms);
    if (settled.kind != Event::Kind::kNone) return settled;
    if (has_frames_ && (active_ == 0 || Stalled(now_ms))) {
      return Switch(now_ms, active_ == 0 ? Reason::kFirst : Reason::kStalled);
    }
    return Event();
  }

  uint64_t active() const { return active_; }
  uint64_t candidate() const { return candidate_; }

 private:
  int64_t StalledAfterMs() const {
    return std::max(kStalledMs, kStalledIntervals * std::max(interval_max_, interval_max_prev_));
  }

  bool Stalled(int64_t now_ms) const { return !active_alive_ || now_ms - active_last_ms_ > StalledAfterMs(); }

  // Буфер писателя: его интервал — в окно наибольших; окно сменяется раз в kCadenceWindowMs, порог смотрит текущее и прошлое.
  void NoteWriterBuffer(int64_t now_ms) {
    if (now_ms - window_start_ms_ >= kCadenceWindowMs) {
      interval_max_prev_ = interval_max_;
      interval_max_ = 0;
      window_start_ms_ = now_ms;
    }
    interval_max_ = std::max(interval_max_, now_ms - active_last_ms_);
    active_last_ms_ = now_ms;
  }

  Event CheckDead(int64_t now_ms) {
    if (active_ == 0 || !active_alive_ || dead_reported_ || now_ms - active_last_ms_ <= kDeadMs) return Event();
    dead_reported_ = true;
    Event event;
    event.kind = Event::Kind::kActiveDead;
    event.stream = active_;
    event.wait_ms = now_ms - active_last_ms_;
    return event;
  }

  void CheckCeiling(int64_t now_ms) {
    if (ready_ == Reason::kNone && has_frames_ && now_ms - first_frame_ms_ >= ceiling_ms_) ready_ = Reason::kCeiling;
  }

  Event Settle(int64_t now_ms) {
    if (!has_frames_ && started_ && now_ms - started_ms_ >= kNoFramesMs) {
      Event event;
      event.kind = Event::Kind::kCancelled;
      event.stream = candidate_;
      event.reason = Reason::kNoFrames;
      event.wait_ms = now_ms - begin_ms_;
      candidate_ = 0;
      return event;
    }
    CheckCeiling(now_ms);
    return Event();
  }

  Event Switch(int64_t now_ms, Reason reason) {
    Event event;
    event.kind = Event::Kind::kSwitched;
    event.stream = candidate_;
    event.retired = active_;
    event.reason = reason;
    event.wait_ms = now_ms - begin_ms_;
    // Прежнему вернётся право, если нового снимут раньше, чем закроют его (Drop); снятый до передачи его не получит.
    retired_ = active_alive_ ? active_ : 0;
    Become(candidate_, now_ms);
    candidate_ = 0;
    ready_ = Reason::kNone;
    return event;
  }

  void Become(uint64_t stream, int64_t now_ms) {
    active_ = stream;
    active_last_ms_ = now_ms;
    active_alive_ = true;
    dead_reported_ = false;
    window_start_ms_ = now_ms;
    interval_max_ = 0;
    interval_max_prev_ = 0;
  }

  uint64_t active_ = 0;
  int64_t active_last_ms_ = 0;
  bool active_alive_ = true;
  bool dead_reported_ = false;  // kActiveDead для этого писателя уже было
  int64_t window_start_ms_ = 0;
  int64_t interval_max_ = 0;       // наибольший интервал писателя в текущем окне
  int64_t interval_max_prev_ = 0;  // и в прошлом
  uint64_t retired_ = 0;  // прежний писатель, живой на передаче, пока его не закрыли (Drop)
  uint64_t candidate_ = 0;
  int64_t begin_ms_ = 0;  // открытие нового: от него wait_ms событий
  int64_t ceiling_ms_ = kCeilingWiredMs;
  bool started_ = false;
  int64_t started_ms_ = 0;
  bool has_frames_ = false;
  int64_t first_frame_ms_ = 0;
  Reason ready_ = Reason::kNone;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_DEVICE_CAPTURE_HANDOFF_H_
