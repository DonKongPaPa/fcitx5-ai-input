#ifndef _FCITX5_AIINPUT_UI_TRAY_MENU_H_
#define _FCITX5_AIINPUT_UI_TRAY_MENU_H_

// AI Input 自有托盘（对比工具条）：fcitx5 内建 SNI 属 classicui——本 UI
// 胜出后其 suspend() 会 disable 内建托盘。此托盘随本 addon 常驻，菜单三
// 项：bug 标记 / Flutter⇄QML 卡切换 / classicui⇄aiinput UI 切换。
// 协议模式照搬 fcitx5 notificationitem 模块（私有 Bus + SNI + dbusmenu）。

#include <fcitx-utils/dbus/bus.h>
#include <fcitx-utils/dbus/message.h>
#include <fcitx-utils/dbus/objectvtable.h>
#include <fcitx-utils/dbus/variant.h>
#include <fcitx-utils/event.h>

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

namespace fcitx {

class AiInputUi;

using MenuProperty = dbus::DictEntry<std::string, dbus::Variant>;
using MenuProperties = std::vector<MenuProperty>;
using PixmapList = std::vector<
    dbus::DBusStruct<int32_t, int32_t, std::vector<uint8_t>>>;
using MenuLayout =
    dbus::DBusStruct<int32_t, MenuProperties, std::vector<dbus::Variant>>;

// com.canonical.dbusmenu——三项平铺（id 1=bug 标记 2=卡切换 3=UI 切换）
class AiInputMenu : public dbus::ObjectVTable<AiInputMenu> {
public:
    explicit AiInputMenu(AiInputUi *ui) : ui_(ui) {}

private:
    void event(int32_t id, const std::string &type, const dbus::Variant &data,
               uint32_t timestamp);
    dbus::Variant getProperty(int32_t id, const std::string &name);
    std::tuple<uint32_t, MenuLayout>
    getLayout(int32_t parentId, int32_t depth,
              const std::vector<std::string> &propertyNames);
    std::vector<dbus::DBusStruct<int32_t, MenuProperties>>
    getGroupProperties(const std::vector<int32_t> &ids,
                       const std::vector<std::string> &propertyNames) {
        std::vector<dbus::DBusStruct<int32_t, MenuProperties>> result;
        for (auto id : ids) {
            MenuProperties properties;
            fillProperties(id, properties);
            result.emplace_back(id, std::move(properties));
        }
        return result;
    }
    bool aboutToShow(int32_t) { return false; }
    void fillProperties(int32_t id, MenuProperties &properties);
    void fillLayoutItem(int32_t id, int32_t depth,
                        const std::unordered_set<std::string> &names,
                        MenuLayout &layout);

    AiInputUi *ui_;
    uint32_t revision_ = 3;

public:
    FCITX_OBJECT_VTABLE_PROPERTY(version, "Version", "u",
                                 []() { return uint32_t(3); });
    FCITX_OBJECT_VTABLE_PROPERTY(status, "Status", "s",
                                 []() { return std::string("normal"); });
    FCITX_OBJECT_VTABLE_SIGNAL(itemsPropertiesUpdated, "ItemsPropertiesUpdated",
                               "a(ia{sv})a(ias)");
    FCITX_OBJECT_VTABLE_SIGNAL(layoutUpdated, "LayoutUpdated", "ui");
    FCITX_OBJECT_VTABLE_SIGNAL(itemActivationRequested,
                               "ItemActivationRequested", "iu");
    FCITX_OBJECT_VTABLE_METHOD(event, "Event", "isvu", "");
    FCITX_OBJECT_VTABLE_METHOD(getProperty, "GetProperty", "is", "v");
    FCITX_OBJECT_VTABLE_METHOD(getLayout, "GetLayout", "iias", "u(ia{sv}av)");
    FCITX_OBJECT_VTABLE_METHOD(getGroupProperties, "GetGroupProperties",
                               "aias", "a(ia{sv})");
    FCITX_OBJECT_VTABLE_METHOD(aboutToShow, "AboutToShow", "i", "b");
};

// org.kde.StatusNotifierItem——静态图标 + Menu 指向 AiInputMenu
class AiTraySNI : public dbus::ObjectVTable<AiTraySNI> {
public:
    explicit AiTraySNI(AiInputUi *ui) : ui_(ui) {}

    void activate(int, int);
    void secondaryActivate(int, int) {}
    void scroll(int, const std::string &) {}

private:
    static PixmapList emptyPixmap() { return {}; }
    // 宏参数不可含逗号：带模板实参的返回值一律委托具名函数
    static dbus::DBusStruct<std::string, PixmapList, std::string, std::string>
    tooltipImpl() {
        return {std::string("fcitx"), emptyPixmap(), std::string("AI Input"),
                std::string()};
    }
    AiInputUi *ui_;

public:
    FCITX_OBJECT_VTABLE_METHOD(scroll, "Scroll", "is", "");
    FCITX_OBJECT_VTABLE_METHOD(activate, "Activate", "ii", "");
    FCITX_OBJECT_VTABLE_METHOD(secondaryActivate, "SecondaryActivate", "ii",
                               "");
    FCITX_OBJECT_VTABLE_SIGNAL(newIcon, "NewIcon", "");
    FCITX_OBJECT_VTABLE_SIGNAL(newToolTip, "NewToolTip", "");
    FCITX_OBJECT_VTABLE_PROPERTY(category, "Category", "s",
                                 []() { return std::string("SystemStatus"); });
    FCITX_OBJECT_VTABLE_PROPERTY(id, "Id", "s",
                                 []() { return std::string("FcitxAiInput"); });
    FCITX_OBJECT_VTABLE_PROPERTY(title, "Title", "s",
                                 []() { return std::string("AI Input"); });
    FCITX_OBJECT_VTABLE_PROPERTY(status, "Status", "s",
                                 []() { return std::string("Active"); });
    FCITX_OBJECT_VTABLE_PROPERTY(windowId, "WindowId", "i", []() { return 0; });
    FCITX_OBJECT_VTABLE_PROPERTY(iconName, "IconName", "s",
                                 []() { return std::string("fcitx"); });
    FCITX_OBJECT_VTABLE_PROPERTY(iconPixmap, "IconPixmap", "a(iiay)",
                                 emptyPixmap);
    FCITX_OBJECT_VTABLE_PROPERTY(overlayIconName, "OverlayIconName", "s",
                                 []() { return std::string(); });
    FCITX_OBJECT_VTABLE_PROPERTY(overlayIconPixmap, "OverlayIconPixmap",
                                 "a(iiay)", emptyPixmap);
    FCITX_OBJECT_VTABLE_PROPERTY(attentionIconName, "AttentionIconName", "s",
                                 []() { return std::string(); });
    FCITX_OBJECT_VTABLE_PROPERTY(attentionIconPixmap, "AttentionIconPixmap",
                                 "a(iiay)", emptyPixmap);
    FCITX_OBJECT_VTABLE_PROPERTY(attentionMovieName, "AttentionMovieName", "s",
                                 []() { return std::string(); });
    FCITX_OBJECT_VTABLE_PROPERTY(movieName, "MovieName", "s",
                                 []() { return std::string(); });
    FCITX_OBJECT_VTABLE_PROPERTY(tooltip, "ToolTip", "(sa(iiay)ss)",
                                 tooltipImpl);
    FCITX_OBJECT_VTABLE_PROPERTY(
        menu, "Menu", "o",
        []() { return dbus::ObjectPath("/org/fcitx/AiInput/MenuBar"); });
    FCITX_OBJECT_VTABLE_PROPERTY(itemIsMenu, "ItemIsMenu", "b",
                                 []() { return true; });
};

// 注册编排：watcher 检测 StatusNotifierWatcher → 私有 Bus 挂双对象 → 注册
class AiInputTray {
public:
    explicit AiInputTray(AiInputUi *ui);
    ~AiInputTray();

private:
    void registerSNI();

    AiInputUi *ui_;
    std::unique_ptr<dbus::Bus> privateBus_;
    std::unique_ptr<AiTraySNI> sni_;
    std::unique_ptr<AiInputMenu> menu_;
    std::unique_ptr<dbus::Slot> pendingRegisterCall_;
    std::unique_ptr<EventSourceTime> retryTimer_;
    bool registered_ = false;
};

} // namespace fcitx

#endif // _FCITX5_AIINPUT_UI_TRAY_MENU_H_
