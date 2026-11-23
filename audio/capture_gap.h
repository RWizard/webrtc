/*
 *  Dada (#321): RTP-время звуковой дорожки идёт вместе с часами через любую паузу захвата.
 *
 *  RTP-время дорожки — сумма поданных отсчётов (ChannelSend::ProcessAndEncodeAudio). Когда захват стоит (модуль звука
 *  пересобирает движок при смене микрофона или формата вывода, переподключается Bluetooth, поток захвата не успел), отсчётов
 *  нет, и звук после паузы уходит с меткой, отставшей от часов на длину паузы. Приёмник (NetEq) принимает это за дрожание сети:
 *  растягивает речь несколько секунд и копит лишнюю задержку до конца звонка; сервер записи догоняет сдвиг шагами и пробивает
 *  в записи дыры. Если же метка прыгает на длину паузы, приёмник видит обычный пропуск (как DTX): досочиняет паузу, а дальше
 *  играет вовремя, без растяжки и без задержки (замер петлёй Chrome 23.11: растянуто 0, буфер 20 мс против 849 мс и 860 мс).
 *
 *  Решение — по меткам захвата (absolute_capture_timestamp_ms): ожидаемое время кадра = якорь + звук, отданный после якоря.
 *  Опережение больше порога — пауза: метка прыгает на неё, якорь переносится. Малое опережение (дрожание, часы устройства
 *  медленнее часов хоста) переносит якорь на этот кадр без прыжка. Кадры одного буфера ввода несут одну метку (FineAudioBuffer),
 *  пачки внешнего источника подаются разом — такие кадры «отстают» от ожидания на долю буфера, и по одному кадру якорь не
 *  двигается: раз в окно (дольше любого буфера) якорь сдвигается на наименьшее отставание в окне — у кадра начала буфера.
 *  Так расхождение часов в обе стороны не копится и само прыжков не даёт.
 *
 *  Чистый C++ без зависимостей WebRTC: копия файла с проверкой лежит в репозитории Dada (apps/mobile/plugins/mac-webrtc/fork,
 *  tests/c/CaptureGapCheck.cpp).
 */
#ifndef AUDIO_CAPTURE_GAP_H_
#define AUDIO_CAPTURE_GAP_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace webrtc {

class CaptureGap {
 public:
  // Пауза короче порога не прыжок: её сглаживает приёмник как дрожание сети, а метки буферов и подач гуляют на единицы мс.
  static constexpr int64_t kThresholdMs = 30;
  // Окно поправки отставания: дольше любого буфера ввода (до 64 мс у гарнитуры на 8 кГц) с запасом на растянутую пачку подач.
  static constexpr int64_t kWindowMs = 200;
  // Опережение больше этого — не пауза захвата, а скачок часов (сон Mac и т. п.): якорь переносится без прыжка. Прыжок держится
  // далеко от половины круга 32-битной RTP-метки.
  static constexpr int64_t kMaxGapMs = 10 * 60 * 1000;

  // Сколько отсчётов (на частоте этого кадра) прибавить к RTP-метке перед этим кадром. Ноль — разрыва нет.
  int64_t Advance(std::optional<int64_t> capture_ms, int sample_rate_hz, size_t samples_per_channel) {
    if (!capture_ms || sample_rate_hz <= 0 || samples_per_channel == 0) {
      anchor_ms_.reset();
      last_capture_ms_.reset();
      return 0;
    }
    const int64_t frame = static_cast<int64_t>(samples_per_channel);
    // Кадр начала буфера — первый с новой меткой. Кадры из середины буфера несут метку начала и «опережают» её на долю буфера:
    // якорь по такому кадру дал бы ложный прыжок на следующем буфере, поэтому якорь ставится только на кадр с новой меткой.
    const bool buffer_start = !last_capture_ms_ || *capture_ms != *last_capture_ms_;
    last_capture_ms_ = capture_ms;
    int64_t advance = 0;
    bool reanchor = !anchor_ms_;
    if (anchor_ms_) {
      // Ожидание считается по частоте, на которой отдан звук после якоря: смена микрофона меняет частоту ровно на паузе.
      const int64_t expected_ms = *anchor_ms_ + samples_ * 1000 / rate_;
      const int64_t lead_ms = *capture_ms - expected_ms;
      if (lead_ms >= kThresholdMs && lead_ms <= kMaxGapMs) {
        // Целыми кадрами, с округлением: кадры кодера остаются ровными, остаток не больше половины кадра.
        const int64_t frames = (lead_ms * sample_rate_hz / 1000 + frame / 2) / frame;
        advance = frames * frame;
        reanchor = true;
      } else if (lead_ms > 0 || sample_rate_hz != rate_) {
        reanchor = true;
      } else {
        window_max_lead_ms_ = window_samples_ ? std::max(window_max_lead_ms_, lead_ms) : lead_ms;
        window_samples_ += frame;
        if (window_samples_ * 1000 >= kWindowMs * sample_rate_hz) {
          // Кадр начала буфера отстаёт меньше всех: всё его отставание — расхождение часов, якорь догоняет его без прыжка.
          *anchor_ms_ += window_max_lead_ms_;
          window_samples_ = 0;
        }
      }
    }
    if (reanchor) {
      if (!buffer_start) {
        // Якорь подождёт начала следующего буфера; до него прыжков нет.
        anchor_ms_.reset();
        return advance;
      }
      anchor_ms_ = *capture_ms;
      samples_ = 0;
      rate_ = sample_rate_hz;
      window_samples_ = 0;
    }
    samples_ += frame;
    return advance;
  }

  // Отправка остановлена или начата заново: якорем станет кадр начала буфера (возобновление отправки подтягивает метку само).
  void Reset() { anchor_ms_.reset(); }

 private:
  std::optional<int64_t> anchor_ms_;
  std::optional<int64_t> last_capture_ms_;  // метка прошлого кадра: кадр с новой меткой — начало буфера
  int64_t samples_ = 0;  // отсчёты после якоря на частоте `rate_`
  int rate_ = 0;
  int64_t window_samples_ = 0;       // отсчёты окна поправки отставания
  int64_t window_max_lead_ms_ = 0;   // наименьшее отставание (наибольшее опережение) в окне
};

}  // namespace webrtc

#endif  // AUDIO_CAPTURE_GAP_H_
