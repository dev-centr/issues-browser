module tray.win_tray;

version (Windows) {
import core.sys.windows.windows;
import core.sys.windows.shellapi;
import std.string;
import std.conv;
import std.utf;

enum uint WM_TRAYICON = WM_USER + 1;
enum uint ID_SYNC = 1001;
enum uint ID_STATUS = 1002;
enum uint ID_QUIT = 1003;
enum uint ID_OPEN_ARCHIVES = 1004;

alias TrayCallback = void delegate(uint cmd);

private HWND gHwnd;
private NOTIFYICONDATAW gNid;
private TrayCallback gCb;
private bool gRunning = true;

extern (Windows) LRESULT trayWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow {
	try {
		if (msg == WM_TRAYICON) {
			if (lParam == WM_RBUTTONUP || lParam == WM_LBUTTONUP) {
				POINT pt;
				GetCursorPos(&pt);
				auto menu = CreatePopupMenu();
				AppendMenuW(menu, MF_STRING, ID_STATUS, "Status".toUTF16z);
				AppendMenuW(menu, MF_STRING, ID_SYNC, "Sync now".toUTF16z);
				AppendMenuW(menu, MF_STRING, ID_OPEN_ARCHIVES, "Open archives".toUTF16z);
				AppendMenuW(menu, MF_SEPARATOR, 0, null);
				AppendMenuW(menu, MF_STRING, ID_QUIT, "Quit".toUTF16z);
				SetForegroundWindow(hwnd);
				auto cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, null);
				DestroyMenu(menu);
				if (cmd && gCb !is null) gCb(cast(uint) cmd);
			}
		} else if (msg == WM_DESTROY) {
			Shell_NotifyIconW(NIM_DELETE, &gNid);
			PostQuitMessage(0);
		}
	} catch (Exception) {}
	return DefWindowProcW(hwnd, msg, wParam, lParam);
}

bool startTray(string tooltip, TrayCallback cb) {
	gCb = cb;
	WNDCLASSW wc;
	wc.lpfnWndProc = &trayWndProc;
	wc.hInstance = GetModuleHandleW(null);
	wc.lpszClassName = "IssuesBrowserTray".toUTF16z;
	RegisterClassW(&wc);
	gHwnd = CreateWindowExW(0, wc.lpszClassName, "issues-browser-tray".toUTF16z,
		WS_OVERLAPPED, 0, 0, 0, 0, null, null, wc.hInstance, null);
	if (!gHwnd) return false;

	gNid.cbSize = NOTIFYICONDATAW.sizeof;
	gNid.hWnd = gHwnd;
	gNid.uID = 1;
	gNid.uFlags = NIF_MESSAGE | NIF_TIP | NIF_ICON;
	gNid.uCallbackMessage = WM_TRAYICON;
	gNid.hIcon = LoadIconW(null, IDI_APPLICATION);
	auto tip = tooltip.toUTF16;
	gNid.szTip[0 .. tip.length] = tip[];
	gNid.szTip[tip.length] = 0;
	return Shell_NotifyIconW(NIM_ADD, &gNid) != FALSE;
}

void setTrayTip(string tip) {
	auto t = tip.toUTF16;
	gNid.szTip[] = 0;
	auto n = t.length < gNid.szTip.length - 1 ? t.length : gNid.szTip.length - 1;
	gNid.szTip[0 .. n] = t[0 .. n];
	Shell_NotifyIconW(NIM_MODIFY, &gNid);
}

void runTrayLoop() {
	MSG msg;
	while (gRunning && GetMessageW(&msg, null, 0, 0) > 0) {
		TranslateMessage(&msg);
		DispatchMessageW(&msg);
	}
}

void stopTray() {
	gRunning = false;
	if (gHwnd) PostMessageW(gHwnd, WM_CLOSE, 0, 0);
}

} else {
// Non-Windows stub
alias TrayCallback = void delegate(uint cmd);
enum uint ID_SYNC = 1001;
enum uint ID_STATUS = 1002;
enum uint ID_QUIT = 1003;
enum uint ID_OPEN_ARCHIVES = 1004;
bool startTray(string tooltip, TrayCallback cb) { return false; }
void setTrayTip(string tip) {}
void runTrayLoop() {}
void stopTray() {}
}
