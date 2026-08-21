// aiinput 测试应用（Qt6）
//
// 与 testapp-gtk 等价：单窗口 QLineEdit，焦点/文本变化时输出 JSON 行
// （stdout + TEST_RESULT_FILE），内置 500ms 重绘定时器保证录屏帧连续。
#include <QApplication>
#include <QDateTime>
#include <QFile>
#include <QLineEdit>
#include <QTextEdit>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>

#include <cstdio>

static qint64 monoMs() {
    return QDateTime::currentMSecsSinceEpoch();
}

static QString jsonEscape(const QString &s) {
    QString out;
    for (const QChar &c : s) {
        switch (c.unicode()) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        default: out += c;
        }
    }
    return out;
}

static void emitJson(QLineEdit *edit, const char *event) {
    QString line = QString("{\"app\":\"qt6\",\"event\":\"%1\",\"text\":\"%2\",\"mono_ms\":%3}\n")
                       .arg(QString::fromUtf8(event), jsonEscape(edit->text()))
                       .arg(monoMs());
    fputs(line.toUtf8().constData(), stdout);
    fflush(stdout);
    const char *path = qgetenv("TEST_RESULT_FILE").constData();
    if (path && *path) {
        QFile f(QString::fromUtf8(path));
        if (f.open(QIODevice::Append | QIODevice::Text)) {
            f.write(line.toUtf8());
            f.close();
        }
    }
}

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);

    QWidget win;
    win.setWindowTitle(QStringLiteral("aiinput-testapp-qt"));
    win.resize(640, 220);

    auto *edit = new QLineEdit;
    edit->setPlaceholderText(QStringLiteral("语音输入落点……"));

    auto *layout = new QVBoxLayout(&win);
    layout->addWidget(edit);

    QObject::connect(edit, &QLineEdit::textChanged, edit,
                     [edit] { emitJson(edit, "changed"); });

    win.show();
    edit->setFocus();

    // 持续重绘：保证录屏帧连续（wlroots/niri 按需渲染）
    QTimer repaint;
    repaint.setInterval(500);
    QObject::connect(&repaint, &QTimer::timeout, edit, qOverload<>(&QWidget::update));
    repaint.start();

    bool ok = false;
    const int timeout = qEnvironmentVariableIntValue("TEST_TIMEOUT", &ok);
    QTimer::singleShot(ok && timeout > 0 ? timeout * 1000 : 120000, &app, &QCoreApplication::quit);

    return app.exec();
}
