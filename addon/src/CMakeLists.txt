add_library(voiceinput MODULE)
target_sources(voiceinput PRIVATE
    voiceinput.cpp
)
target_link_libraries(voiceinput PRIVATE Fcitx5::Core)
set_target_properties(voiceinput PROPERTIES PREFIX "")

install(TARGETS voiceinput LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}")

# addon 描述文件 → share/fcitx5/addon/
fcitx5_translate_desktop_file(voiceinput.conf.in voiceinput.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/voiceinput.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

# 输入法条目 → share/fcitx5/inputmethod/（文件名必须等于输入法唯一名）
fcitx5_translate_desktop_file(voiceinput-im.conf.in voiceinput-im.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/voiceinput-im.conf"
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod"
        RENAME voiceinput.conf)
