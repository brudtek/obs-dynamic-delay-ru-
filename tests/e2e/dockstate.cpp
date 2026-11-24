// Prints a QMainWindow::saveState() (base64) in which the plugin dock is a visible floating
// window at the given geometry. Written into the test OBS user.ini as [BasicWindow] DockState,
// so the dock is open without clicking through the Docks menu.
// usage: dockstate.exe -platform minimal <x> <y> <w> <h>
#include <QApplication>
#include <QDockWidget>
#include <QLabel>
#include <QMainWindow>
#include <cstdio>

int main(int argc, char **argv)
{
	QApplication app(argc, argv);
	const QStringList args = app.arguments();
	const int x = args.value(1, "100").toInt(), y = args.value(2, "60").toInt();
	const int w = args.value(3, "400").toInt(), h = args.value(4, "900").toInt();
	QMainWindow window;
	window.setCentralWidget(new QLabel("central"));
	auto *dock = new QDockWidget("dock");
	dock->setObjectName("obs_dynamic_delay_controls");
	dock->setWidget(new QLabel("content"));
	window.addDockWidget(Qt::LeftDockWidgetArea, dock);
	window.resize(1280, 960);
	window.show();
	dock->setFloating(true);
	dock->setGeometry(x, y, w, h);
	dock->show();
	app.processEvents();
	std::printf("%s\n", window.saveState().toBase64().constData());
	return 0;
}
