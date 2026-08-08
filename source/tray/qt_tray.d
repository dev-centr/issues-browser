/** Cross-platform system tray via dqt QSystemTrayIcon (dlang-supplemental/dqt fork). */
module tray.qt_tray;

import core.runtime;
import core.stdcpp.new_;

import qt.config;
import qt.core.object;
import qt.core.string;
import qt.gui.action;
import qt.gui.icon;
import qt.helpers;
import qt.widgets.application;
import qt.widgets.menu;
import qt.widgets.style;
import qt.widgets.systemtrayicon;

enum uint ID_SYNC = 1001;
enum uint ID_STATUS = 1002;
enum uint ID_QUIT = 1003;
enum uint ID_OPEN_ARCHIVES = 1004;

alias TrayCallback = void delegate(uint cmd);

private class TrayController : QObject
{
	mixin(Q_OBJECT_D);

	this(TrayCallback cb)
	{
		super(null);
		this.cb = cb;
	}

private /+ slots +/:
	@QSlot final void onStatus()
	{
		if (cb !is null)
			cb(ID_STATUS);
	}

	@QSlot final void onSync()
	{
		if (cb !is null)
			cb(ID_SYNC);
	}

	@QSlot final void onOpen()
	{
		if (cb !is null)
			cb(ID_OPEN_ARCHIVES);
	}

	@QSlot final void onQuit()
	{
		if (cb !is null)
			cb(ID_QUIT);
	}

private:
	TrayCallback cb;
}

private QApplication gApp;
private QSystemTrayIcon gTray;
private TrayController gController;

bool startTray(string tooltip, TrayCallback cb)
{
	int argc = Runtime.cArgs.argc;
	char** argv = Runtime.cArgs.argv;
	gApp = new QApplication(argc, argv);

	if (!QSystemTrayIcon.isSystemTrayAvailable())
		return false;

	gController = cpp_new!TrayController(cb);

	auto menu = cpp_new!QMenu();
	auto actStatus = menu.addAction(QString("Status"));
	auto actSync = menu.addAction(QString("Sync now"));
	auto actOpen = menu.addAction(QString("Open archives"));
	menu.addSeparator();
	auto actQuit = menu.addAction(QString("Quit"));

	QObject.connect(actStatus.signal!"triggered", gController.slot!"onStatus");
	QObject.connect(actSync.signal!"triggered", gController.slot!"onSync");
	QObject.connect(actOpen.signal!"triggered", gController.slot!"onOpen");
	QObject.connect(actQuit.signal!"triggered", gController.slot!"onQuit");

	gTray = cpp_new!QSystemTrayIcon();
	gTray.setIcon(gApp.style().standardIcon(QStyle.StandardPixmap.SP_ComputerIcon));
	gTray.setToolTip(QString(tooltip));
	gTray.setContextMenu(menu);
	gTray.show();
	return true;
}

void setTrayTip(string tip)
{
	if (gTray !is null)
		gTray.setToolTip(QString(tip));
}

void runTrayLoop()
{
	if (gApp !is null)
		gApp.exec();
}

void stopTray()
{
	if (gTray !is null)
		gTray.hide();
	if (gApp !is null)
		gApp.quit();
}
