// Analyzer for end-to-end delay tests on a recording or a received FLV stream.
// Video: colour of the centre pixel (red = hold scene, blue = live 1, green = live 2).
// Audio: amplitude of the 440 Hz (hold-only tone) and 880 Hz (shared tone) components
// per AAC frame (Goertzel), merged into segments. Also checks timestamp monotonicity.
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

const char *classify(int y, int u, int v)
{
	if (v > 170 && u < 140)
		return "КРАСНЫЙ (ожидание)";
	if (u > 170 && v < 140)
		return "СИНИЙ (Эфир)";
	if (u < 110 && v < 110 && y > 100)
		return "ЗЕЛЁНЫЙ (Эфир 2)";
	return "другой";
}

// Amplitude of a sinusoid at freq in samples (Goertzel, normalised to peak amplitude).
double tone_amplitude(const float *x, int n, double freq, int rate)
{
	const double w = 2.0 * 3.14159265358979323846 * freq / rate;
	const double c = 2.0 * std::cos(w);
	double s1 = 0.0, s2 = 0.0;
	for (int i = 0; i < n; ++i) {
		const double s0 = x[i] + c * s1 - s2;
		s2 = s1;
		s1 = s0;
	}
	const double power = s1 * s1 + s2 * s2 - c * s1 * s2;
	return 2.0 * std::sqrt(std::max(power, 0.0)) / n;
}

struct AudioSeg {
	std::string label;
	double start = 0, end = 0, a440 = 0, a880 = 0;
	int frames = 0;
};

std::string audio_label(double a440, double a880)
{
	const double on = 0.03;
	if (a440 > on && a880 > on)
		return "440+880";
	if (a440 > on)
		return "440";
	if (a880 > on)
		return "880";
	return "тишина";
}

} // namespace

int main(int argc, char **argv)
{
	if (argc < 2) {
		std::fprintf(stderr, "usage: analyze file\n");
		return 2;
	}
	AVFormatContext *fmt = nullptr;
	if (avformat_open_input(&fmt, argv[1], nullptr, nullptr) < 0 || avformat_find_stream_info(fmt, nullptr) < 0) {
		std::fprintf(stderr, "cannot open %s\n", argv[1]);
		return 1;
	}
	const int vIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
	const int aIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
	AVStream *vs = fmt->streams[vIndex];
	const AVCodec *vcodec = avcodec_find_decoder(vs->codecpar->codec_id);
	AVCodecContext *vdec = avcodec_alloc_context3(vcodec);
	avcodec_parameters_to_context(vdec, vs->codecpar);
	avcodec_open2(vdec, vcodec, nullptr);
	AVCodecContext *adec = nullptr;
	AVStream *as = aIndex >= 0 ? fmt->streams[aIndex] : nullptr;
	if (as) {
		const AVCodec *acodec = avcodec_find_decoder(as->codecpar->codec_id);
		adec = avcodec_alloc_context3(acodec);
		avcodec_parameters_to_context(adec, as->codecpar);
		avcodec_open2(adec, acodec, nullptr);
	}

	AVPacket *pkt = av_packet_alloc();
	AVFrame *frame = av_frame_alloc();
	std::string current;
	double segStart = 0, lastT = 0;
	int64_t lastVideoDts = INT64_MIN, lastAudioPts = INT64_MIN;
	int videoRegress = 0, audioRegress = 0, videoFrames = 0, decodeErrors = 0;
	double maxGap = 0, maxGapAt = 0, lastAudioEnd = -1;
	std::vector<AudioSeg> audioSegs;
	std::printf("Видео (цвет центра кадра), с:\n");

	auto on_video = [&](AVFrame *f) {
		const double t = f->best_effort_timestamp * av_q2d(vs->time_base);
		++videoFrames;
		const int cx = f->width / 2, cy = f->height / 2;
		const std::string c = classify(f->data[0][cy * f->linesize[0] + cx],
					       f->data[1][(cy / 2) * f->linesize[1] + cx / 2],
					       f->data[2][(cy / 2) * f->linesize[2] + cx / 2]);
		if (c != current) {
			if (!current.empty())
				std::printf("  %8.2f – %8.2f  %s\n", segStart, lastT, current.c_str());
			current = c;
			segStart = t;
		}
		lastT = t;
	};
	auto on_audio = [&](AVFrame *f, double t) {
		if (f->format != AV_SAMPLE_FMT_FLTP || f->nb_samples == 0)
			return;
		const float *x = reinterpret_cast<const float *>(f->data[0]);
		const double a440 = tone_amplitude(x, f->nb_samples, 440.0, f->sample_rate);
		const double a880 = tone_amplitude(x, f->nb_samples, 880.0, f->sample_rate);
		const double end = t + static_cast<double>(f->nb_samples) / f->sample_rate;
		const std::string label = audio_label(a440, a880);
		if (audioSegs.empty() || audioSegs.back().label != label)
			audioSegs.push_back({label, t, end, 0, 0, 0});
		AudioSeg &s = audioSegs.back();
		s.end = end;
		s.a440 += a440;
		s.a880 += a880;
		++s.frames;
	};

	while (av_read_frame(fmt, pkt) >= 0) {
		if (pkt->stream_index == vIndex) {
			if (pkt->dts != AV_NOPTS_VALUE) {
				if (pkt->dts <= lastVideoDts)
					++videoRegress;
				lastVideoDts = pkt->dts;
			}
			if (avcodec_send_packet(vdec, pkt) < 0)
				++decodeErrors;
			while (avcodec_receive_frame(vdec, frame) == 0)
				on_video(frame);
		} else if (as && pkt->stream_index == aIndex && pkt->pts != AV_NOPTS_VALUE) {
			if (pkt->pts <= lastAudioPts)
				++audioRegress;
			lastAudioPts = pkt->pts;
			const double start = pkt->pts * av_q2d(as->time_base);
			if (lastAudioEnd >= 0 && start - lastAudioEnd > 0.03)
				std::printf("  разрыв звука %.3f с на %.2f с\n", start - lastAudioEnd, start);
			if (lastAudioEnd >= 0 && start - lastAudioEnd > maxGap) {
				maxGap = start - lastAudioEnd;
				maxGapAt = start;
			}
			lastAudioEnd = start + pkt->duration * av_q2d(as->time_base);
			if (avcodec_send_packet(adec, pkt) == 0)
				while (avcodec_receive_frame(adec, frame) == 0)
					on_audio(frame, start);
		}
		av_packet_unref(pkt);
	}
	avcodec_send_packet(vdec, nullptr);
	while (avcodec_receive_frame(vdec, frame) == 0)
		on_video(frame);
	if (!current.empty())
		std::printf("  %8.2f – %8.2f  %s\n", segStart, lastT, current.c_str());

	std::printf("Звук (средняя амплитуда тона 440 Гц / 880 Гц), с:\n");
	for (const AudioSeg &s : audioSegs) {
		if (s.frames < 3 && &s != &audioSegs.front() && &s != &audioSegs.back()) {
			std::printf("  %8.2f – %8.2f  (переход %d кадр.)\n", s.start, s.end, s.frames);
			continue;
		}
		std::printf("  %8.2f – %8.2f  %-8s 440: %.3f  880: %.3f\n", s.start, s.end, s.label.c_str(),
			    s.a440 / s.frames, s.a880 / s.frames);
	}
	std::printf("Кадров видео: %d, ошибок декодирования: %d, откатов DTS видео: %d\n", videoFrames, decodeErrors,
		    videoRegress);
	std::printf("Откатов PTS звука: %d, наибольший разрыв звука: %.3f с (на %.2f с)\n", audioRegress, maxGap,
		    maxGapAt);
	av_frame_free(&frame);
	av_packet_free(&pkt);
	avcodec_free_context(&vdec);
	if (adec)
		avcodec_free_context(&adec);
	avformat_close_input(&fmt);
	return 0;
}
