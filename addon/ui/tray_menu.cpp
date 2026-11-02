#include "tray_menu.h"

#include "fcitx-utils/i18n.h"
#include "ui_addon.h"

#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/instance.h>
#include <dbus_public.h> // Arch Fcitx5ModuleDBus config 根=叶子目录

#include <algorithm>
#include <fstream>

namespace fcitx {

namespace {

constexpr char kWatcherName[] = "org.kde.StatusNotifierWatcher";
constexpr char kWatcherObj[] = "/StatusNotifierWatcher";
constexpr char kWatcherIface[] = "org.kde.StatusNotifierWatcher";
constexpr char kSniIface[] = "org.kde.StatusNotifierItem";
constexpr char kSniObj[] = "/org/fcitx/AiInput/Tray";
constexpr char kMenuIface[] = "com.canonical.dbusmenu";
constexpr char kMenuObj[] = "/org/fcitx/AiInput/MenuBar";

// 菜单项 id：1=bug 标记 2=卡切换 3=UI 切换
constexpr int32_t kItemIdBug = 1;
constexpr int32_t kItemIdCard = 2;
constexpr int32_t kItemIdUi = 3;

} // namespace

AiInputTray::AiInputTray(AiInputUi *ui) : ui_(ui) {
    try {
        auto *dbusMod = ui->instance()->addonManager().addon("dbus", true);
        if (!dbusMod) {
            FCITX_WARN() << "AiInputTray: dbus 模块缺席，托盘不可用";
            return;
        }
        auto *bus = dbusMod->call<IDBusModule::bus>();
        if (!bus) {
            return;
        }
        watcher_ = std::make_unique<dbus::ServiceWatcher>(*bus);
        sni_ = std::make_unique<AiTraySNI>(ui);
        menu_ = std::make_unique<AiInputMenu>(ui);
        watcherEntry_ = watcher_->watchService(
            kWatcherName,
            [this](const std::string &, const std::string &,
                   const std::string &newName) { setServiceName(newName); });
    } catch (const std::exception &e) {
        FCITX_WARN() << "AiInputTray: 初始化失败 " << e.what();
    }
}

AiInputTray::~AiInputTray() = default;

void AiInputTray::setServiceName(const std::string &name) {
    sniWatcherName_ = name;
    registered_ = false;
    if (!sniWatcherName_.empty()) {
        registerSNI();
    }
}

void AiInputTray::registerSNI() {
    if (sniWatcherName_.empty() || registered_ || !sni_ || !menu_) {
        return;
    }
    registered_ = false;
    try {
        auto *dbusMod = ui_->instance()->addonManager().addon("dbus", true);
        if (!dbusMod) {
            return;
        }
        auto *bus = dbusMod->call<IDBusModule::bus>();
        if (!bus) {
            return;
        }
        privateBus_ = std::make_unique<dbus::Bus>(bus->address());
    } catch (...) {
        registered_ = false;
        return;
    }
    privateBus_->attachEventLoop(&ui_->instance()->eventLoop());
    // 对象先挂后注册（SNI 惯例：watcher 注册即回读）
    privateBus_->addObjectVTable(kSniObj, kSniIface, *sni_);
    privateBus_->addObjectVTable(kMenuObj, kMenuIface, *menu_);
    auto call = privateBus_->createMethodCall(
        sniWatcherName_.c_str(), kWatcherObj, kWatcherIface,
        "RegisterStatusNotifierItem");
    call << privateBus_->uniqueName();
    pendingRegisterCall_ = call.callAsync(0, [this](dbus::Message &msg) {
        std::unique_ptr<dbus::Slot> call = std::move(pendingRegisterCall_);
        registered_ = !msg.isError();
        FCITX_INFO() << "AiInputTray: SNI 注册 "
                     << (registered_ ? "成功" : "失败");
        return true;
    });
    privateBus_->flush();
}

// —— AiInputMenu ———————————————————————————————————————————

void AiInputMenu::fillProperties(int32_t id, MenuProperties &properties) {
    if (id == 0) {
        properties.emplace_back("children-display",
                                dbus::Variant(std::string("submenu")));
        return;
    }
    properties.emplace_back("type", dbus::Variant(std::string("standard")));
    properties.emplace_back("enabled", dbus::Variant(true));
    switch (id) {
    case kItemIdBug:
        properties.emplace_back(
            "label", dbus::Variant(std::string("标记上次输入为 Bug")));
        break;
    case kItemIdCard:
        properties.emplace_back("label",
                                dbus::Variant(ui_->cardToggleLabel()));
        break;
    case kItemIdUi:
        properties.emplace_back("label",
                                dbus::Variant(ui_->uiToggleLabel()));
        break;
    default:
        break;
    }
}

dbus::Variant AiInputMenu::getProperty(int32_t id, const std::string &name) {
    MenuProperties properties;
    fillProperties(id, properties);
    for (auto &p : properties) {
        if (p.key() == name) {
            return p.value();
        }
    }
    return dbus::Variant();
}

void AiInputMenu::fillLayoutItem(
    int32_t id, int32_t depth, const std::unordered_set<std::string> &names,
    MenuLayout &layout) {
    std::get<0>(layout) = id;
    fillProperties(id, std::get<1>(layout));
    auto &sub = std::get<2>(layout);
    if (id < 0 || depth == 0) {
        return;
    }
    if (id == 0) {
        for (int32_t child : {kItemIdBug, kItemIdCard, kItemIdUi}) {
            MenuLayout subLayout;
            fillLayoutItem(child, depth - 1, names, subLayout);
            sub.emplace_back(std::move(subLayout));
        }
    }
}

std::tuple<uint32_t, MenuLayout>
AiInputMenu::getLayout(int32_t parentId, int32_t depth,
                       const std::vector<std::string> &propertyNames) {
    std::unordered_set<std::string> names(propertyNames.begin(),
                                          propertyNames.end());
    MenuLayout layout;
    fillLayoutItem(parentId, depth, names, layout);
    return {revision_, std::move(layout)};
}


void AiInputMenu::event(int32_t id, const std::string &type,
                        const dbus::Variant &, uint32_t) {
    if (type != "clicked") {
        return;
    }
    switch (id) {
    case kItemIdBug:
        ui_->markBug();
        break;
    case kItemIdCard:
        ui_->toggleCard();
        break;
    case kItemIdUi:
        ui_->toggleUi();
        break;
    default:
        break;
    }
}

// —— AiTraySNI ———————————————————————————————————————————————

void AiTraySNI::activate(int, int) {
    // 左键不做动作（对比切换在右键菜单，防误触）
}

// —— 出口（AiInputUi 侧实现，tray_menu 只管协议）——
// markBug/toggleCard/toggleUi/cardToggleLabel/uiToggleLabel 见 ui_addon.cpp

} // namespace fcitx
