Name:           fcitx5-voice-input
Version:        0.2.0
Release:        1%{?dist}
Summary:        Fcitx5 voice input: ASR + LLM-polished candidates with Flutter overlay

License:        MIT
URL:            https://github.com/DonKongPaPa/fcitx5-voice-input
BuildArch:      x86_64
Requires:       fcitx5
Requires:       pulseaudio-utils

%description
Voice input for fcitx5: FunASR streaming (31 languages) or local GGUF
engine, Flutter Material 3 overlay near the cursor, LLM-polished
candidate selection (keyboard/mouse), hot-reload settings via
fcitx5-configtool.

%prep

%build

%install
# 构建已在 stage.sh 完成（含预编译 Flutter bundle），直接铺 buildroot
cp -a %{_stage_src}/usr %{buildroot}/

%files
%{_libdir}/fcitx5/voiceinput.so
%{_libdir}/fcitx5-voiceinput/libflutter_engine.so
%{_libdir}/fcitx5-voiceinput/libsherpa-onnx-c-api.so
%{_libdir}/fcitx5-voiceinput/libonnxruntime.so
%{_libdir}/fcitx5-voiceinput/funasr-server/server.py
%{_libdir}/fcitx5-voiceinput/funasr-server/funasr-serve.sh
/usr/share/fcitx5/addon/voiceinput.conf
/usr/share/fcitx5-voiceinput/flutter/flutter_assets
/usr/share/fcitx5-voiceinput/flutter/icudtl.dat
/usr/share/doc/fcitx5-voice-input/LICENSE

%changelog
* Tue Aug 19 2026 DonKongPaPa <raykent92@gmail.com> - 0.2.0-1
- Embedded Flutter engine (raw embedder, software rendering), no GTK window
- Coexist with any input method (global PreInputMethod hotkey, no IM entry)

* Tue Aug 18 2026 DonKongPaPa <raykent92@gmail.com> - 0.1.0-1
- First release: FunASR dual-tier engines + Flutter MD3 overlay + configtool deploy settings
