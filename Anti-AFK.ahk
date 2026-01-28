;     /$$$$$$              /$$     /$$          /$$$$$$  /$$$$$$$$ /$$   /$$
;    /$$__  $$            | $$    |__/         /$$__  $$| $$_____/| $$  /$$/
;   | $$  \ $$ /$$$$$$$  /$$$$$$   /$$        | $$  \ $$| $$      | $$ /$$/
;   | $$$$$$$$| $$__  $$|_  $$_/  | $$ /$$$$$$| $$$$$$$$| $$$$$   | $$$$$/
;   | $$__  $$| $$  \ $$  | $$    | $$|______/| $$__  $$| $$__/   | $$  $$
;   | $$  | $$| $$  | $$  | $$ /$$| $$        | $$  | $$| $$      | $$\  $$
;   | $$  | $$| $$  | $$  |  $$$$/| $$        | $$  | $$| $$      | $$ \  $$
;   |__/  |__/|__/  |__/   \___/  |__/        |__/  |__/|__/      |__/  \__/
; 
#Requires AutoHotkey v2.0

; ------------------------------------------------------------------------------
;                               Configuration
; ------------------------------------------------------------------------------
; POLL_INTERVAL (Seconds):
;   This is the interval which Anti-AFK checks for new windows and calculates
;   how much time is left before exisiting windows become inactve.
POLL_INTERVAL := 5

; WINDOW_TIMEOUT (Minutes):
;   This is the amount of time before a window is considered inactive. After
;   a window has timed out, Anti-AFK will start resetting any AFK timers.
WINDOW_TIMEOUT := 10

; TASK (Function):
;   This is a function that will be ran by the script in order to reset any
;   AFK timers. The target window will have focus while it is being executed.
;   You can customise this function freely - just make sure it resets the timer.
TASK := () => (
    Send("{Space Down}")
    Sleep(50)
    Send("{Space Up}")
)

; TASK_INTERVAL (Minutes):
;   This is the amount of time the script will wait after calling the TASK function
;   before calling it again.
TASK_INTERVAL := 15

; BLOCK_INPUT (Boolean):
;   This tells the script whether you want to block input whilst it shuffles
;   windows and sends input. This requires administrator permissions and is
;   therefore disabled by default. If input is not blocked, keystrokes from the
;   user may 'leak' into the window while Anti-AFK moves it into focus.
BLOCK_INPUT := False

; FOCUS_FALLBACK (String):
;   If Anti-AFK cannot restore focus to the window you were using before it sent
;   input, this controls where focus should go instead.
;   Options:
;     - "Taskbar" (default): activate the Windows taskbar.
;     - "None": do nothing.
;     - Custom: any WinTitle string (e.g. "ahk_exe explorer.exe").
FOCUS_FALLBACK := "Taskbar"

; HIDE_WITH_TRANSPARENCY (Boolean):
;   If enabled, background windows are made transparent while Anti-AFK briefly
;   brings them to the foreground to send input.
HIDE_WITH_TRANSPARENCY := True

; TRAYTIP_ON_ERROR (Boolean):
;   If enabled, Anti-AFK will show a throttled TrayTip when it encounters errors
;   (for example when it cannot activate a window or restore focus).
TRAYTIP_ON_ERROR := True

; TRAYTIP_THROTTLE_SECONDS (Number):
;   Minimum number of seconds between TrayTips for the same error type/process.
TRAYTIP_THROTTLE_SECONDS := 30

; PROCESS_LIST (Array):
;   This is a list of processes that Anti-AFK will montior. Any windows that do
;   not belong to any of these processes will be ignored.
PROCESS_LIST := ["notepad.exe", "wordpad.exe"]

; PROCESS_OVERRIDES (Associative Array):
;   This allows you to specify specific values of WINDOW_TIMEOUT, TASK_INTERVAL,
;   TASK and BLOCK_INPUT for specific processes. This is helpful if different
;   games consider you AFK at wildly different times, or if the function to
;   reset the AFK timer does not work as well across different applications.
PROCESS_OVERRIDES := Map(
    "wordpad.exe", Map(
        "WINDOW_TIMEOUT", 5,
        "TASK_INTERVAL", 5,
        "FOCUS_FALLBACK", "Taskbar",
        "BLOCK_INPUT", False,
        "HIDE_WITH_TRANSPARENCY", True,
        "TASK", () => (
            Send("w")
        )
    )
)

; ------------------------------------------------------------------------------
;                                    Script
; ------------------------------------------------------------------------------
#SingleInstance
InstallKeybdHook()
InstallMouseHook()

windowList := Map()
for _, program in PROCESS_LIST
    windowList[program] := Map()

transparencyOverrides := Map()

cleanupOnExit(*)
{
    global transparencyOverrides

    for hwnd, previousTransparency in transparencyOverrides
        restoreTransparency("ahk_id " hwnd, previousTransparency)

    try BlockInput("Off")
}

OnExit(cleanupOnExit)

updateInProgress := False

errorState := Map(
    "count", 0,
    "lastMessage", "",
    "lastTime", "",
    "notifyTimes", Map(),
    "seen", Map()
)

; Check if the script is running as admin and if keystrokes need to be blocked. If it does not have admin
; privileges the user is prompted to elevate it's permissions. Should they deny, the ability to block input
; is disabled and the script continues as normal.
if (!A_IsAdmin)
{
    requireAdmin := BLOCK_INPUT
    blockedPrograms := []
    for program, override in PROCESS_OVERRIDES
        if (override.Has("BLOCK_INPUT") && override["BLOCK_INPUT"])
        {
            requireAdmin := True
            blockedPrograms.Push(program)
        }

    if (requireAdmin)
    {
        try
        {
            if A_IsCompiled
                RunWait('*RunAs "' A_ScriptFullPath '" /restart')
            else
                RunWait('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
        }

        MsgBox(
            "This requires Anti-AFK to be run as Admin`nIt has been temporarily disabled",
            "Cannot Block Keystrokes", "OK Icon!"
        )

        message := "BLOCK_INPUT requested but script is not running as admin; input blocking disabled"
        if (blockedPrograms.Length > 0)
        {
            overridesText := ""
            for i, p in blockedPrograms
                overridesText .= (i = 1 ? "" : ", ") p

            message := message " (overrides: " overridesText ")"
        }
        ReportIssue("InputBlockingDisabled", message)
    }
}

; Reset the AFK timer for a particular window, blocking input if required.
; Input is sent directly to the target window if it's active; If there is no active window the target
; window is made active.
; If another window is active, its handle is stored while the target is made transparent and activated.
; Any AFK timers are reset and the target is sent to the back before being made opaque again. Focus is then
; restored to the original window.
resetTimer(windowID, resetAction, DenyInput)
{
    activeInfo := getWindowInfo("A")
    targetInfo := getWindowInfo("ahk_id " windowID)

    if (!targetInfo.Count)
        return False

    program := targetInfo["EXE"]
    targetHwnd := targetInfo["ID"]
    targetWindow := "ahk_id " targetInfo["ID"]

    ; Send input directly if the target window is already active.
    if (WinActive(targetWindow))
    {
        resetAction()
        return True
    }

    activeIsDesktop := (!activeInfo.Count || (activeInfo["CLS"] = "WorkerW" || activeInfo["CLS"] = "Progman"))

    hideWithTransparency := getValue("HIDE_WITH_TRANSPARENCY", program)

    pendingIssueKind := ""
    pendingIssueMessage := ""
    pendingIssueOnce := False
    pendingIssueProgram := program
    result := True

    inputWasBlocked := False
    transparencyApplied := False
    previousTransparency := ""
    usedInputBlocking := False
    usedTransparency := False

    try
    {
        while True
        {
            if (DenyInput && A_IsAdmin)
            {
                BlockInput("On")
                inputWasBlocked := True
                usedInputBlocking := True
            }

            if (hideWithTransparency)
            {
                try previousTransparency := WinGetTransparent(targetWindow)
                try
                {
                    WinSetTransparent(0, targetWindow)
                    transparencyApplied := True
                    usedTransparency := True
                    transparencyOverrides[targetHwnd] := previousTransparency
                }
            }

            if (!activateWindow(targetWindow))
            {
                pendingIssueKind := "TargetActivateTimeout"
                pendingIssueMessage := "Timed out activating " program
                result := False
                break
            }

            try
            {
                resetAction()
            }
            catch as e
            {
                pendingIssueKind := "TaskFailed"
                pendingIssueMessage := program " TASK failed: " e.Message
                result := False
                break
            }

            WinMoveBottom(targetWindow)

            if (transparencyApplied)
            {
                if (restoreTransparency(targetWindow, previousTransparency))
                {
                    transparencyApplied := False
                    if (transparencyOverrides.Has(targetHwnd))
                        transparencyOverrides.Delete(targetHwnd)
                }
            }

            restoredFocus := False
            if (!activeIsDesktop)
            {
                oldActiveWindow := getWindow(
                    activeInfo["ID"],
                    activeInfo["PID"],
                    activeInfo["EXE"],
                    ""
                )

                if (oldActiveWindow && activateWindow(oldActiveWindow))
                    restoredFocus := True
            }

            if (restoredFocus)
                break

            if (WinActive(targetWindow))
            {
                fallbackWindow := getFocusFallback(program)
                if (!fallbackWindow)
                {
                    pendingIssueKind := "FocusRestoreFailed"
                    pendingIssueMessage := "Could not restore focus for " program " (no fallback)"
                    result := True
                    break
                }

                if (activateWindow(fallbackWindow))
                {
                    configuredFallback := Trim(getValue("FOCUS_FALLBACK", program))
                    configuredFallback := configuredFallback ? configuredFallback : "None"

                    pendingIssueKind := "FocusFallbackUsed"
                    pendingIssueMessage := "Using focus fallback: " configuredFallback
                    result := True
                    break
                }

                pendingIssueKind := "FocusFallbackFailed"
                pendingIssueMessage := "Focus restore failed; fallback did not activate (" program ")"
                result := True
                break
            }

            break
        }
    }
    finally
    {
        if (transparencyApplied)
        {
            restoreTransparency(targetWindow, previousTransparency)
        }

        if (transparencyOverrides.Has(targetHwnd))
            transparencyOverrides.Delete(targetHwnd)

        if (inputWasBlocked)
            BlockInput("Off")
    }

    if (pendingIssueKind)
    {
        cleanupText := ""
        if (usedInputBlocking)
            cleanupText := cleanupText (cleanupText ? "; " : "") "input unblock attempted"
        if (usedTransparency)
            cleanupText := cleanupText (cleanupText ? "; " : "") "transparency restore attempted"

        message := pendingIssueMessage
        if (cleanupText)
            message := message " (cleanup: " cleanupText ")"

        ReportIssue(pendingIssueKind, message, pendingIssueProgram, pendingIssueOnce)
    }

    return result
}

restoreTransparency(targetWindow, previousTransparency)
{
    if (!WinExist(targetWindow))
        return True

    try
    {
        if (previousTransparency = "" || StrLower(previousTransparency) = "off")
            WinSetTransparent("Off", targetWindow)
        else
            WinSetTransparent(previousTransparency, targetWindow)

        return True
    }
    catch
    {
        return False
    }
}

; Fetch the window which best matches the given criteria.
; Some windows are ephemeral and will be closed after user input. In this case we try
; increasingly vague identifiers until we find a related window. If a window is still
; not found a fallback is used instead.
getWindow(window_ID, process_ID, process_name, fallback)
{
    if (WinExist("ahk_id " window_ID))
        return "ahk_id " window_ID
    
    if (WinExist("ahk_pid " process_ID))
        return "ahk_pid " process_ID

    if (WinExist("ahk_exe " process_name))
        return "ahk_exe " process_name

    return fallback
}

; Get information about a window so that it can be found and reactivated later.
getWindowInfo(target)
{
    windowInfo := Map()

    if (!WinExist(target))
        return windowInfo

    windowInfo["ID"] := WinGetID(target)
    windowInfo["CLS"] := WinGetClass(target)
    windowInfo["PID"] := WinGetPID(target)
    windowInfo["EXE"] := WinGetProcessName(target)

    return windowInfo
}

; Activate a window and yield until it does so.
activateWindow(target, timeoutSeconds := 2)
{
    if (!WinExist(target))
        return False

    WinActivate(target)
    return WinWaitActive(target, , timeoutSeconds) != 0
}

; Calculate the number of polls it will take for the time (in minutes) to pass.
getLoops(value)
{
    return Max(1, Round(value*60 / POLL_INTERVAL))
}

; Find and return a specific attribute for a program, prioritising values in PROCESS_OVERRIDES.
; If an override has not been setup for that process, the default value for all programs will be used instead.
getValue(value, program)
{
    if (PROCESS_OVERRIDES.Has(program) && PROCESS_OVERRIDES[program].Has(value))
        return PROCESS_OVERRIDES[program][value]
    
    return %value%
}

ReportIssue(kind, message, program := "", once := False)
{
    global errorState
    global TRAYTIP_ON_ERROR
    global TRAYTIP_THROTTLE_SECONDS

    issueKey := kind
    if (program)
        issueKey := issueKey "|" program

    if (once)
    {
        if (errorState["seen"].Has(issueKey))
            return

        errorState["seen"][issueKey] := True
    }

    errorState["count"] += 1
    errorState["lastMessage"] := message
    errorState["lastTime"] := FormatTime(, "HH:mm:ss")

    if (!TRAYTIP_ON_ERROR)
        return

    now := A_TickCount
    lastNotify := errorState["notifyTimes"].Has(issueKey) ? errorState["notifyTimes"][issueKey] : 0
    if (now - lastNotify < TRAYTIP_THROTTLE_SECONDS * 1000)
        return

    errorState["notifyTimes"][issueKey] := now
    TrayTip(message, "Anti-AFK")
}

appendErrorSummary(tip)
{
    global errorState

    if (errorState["count"] <= 0)
        return tip

    summary := "Last issue (" errorState["count"] "): " errorState["lastMessage"]
    if (errorState["lastTime"])
        summary := summary " @ " errorState["lastTime"]

    return tip "`n`n" summary
}

; Resolve a focus fallback target based on configuration.
; Returns a WinTitle string (or an empty string to indicate no fallback).
getFocusFallback(program)
{
    fallback := getValue("FOCUS_FALLBACK", program)
    fallback := Trim(fallback)

    if (!fallback)
        return ""

    switch StrLower(fallback)
    {
        case "none":
            return ""
        case "taskbar":
            return "ahk_class Shell_TrayWnd"
        case "desktop":
            ReportIssue("InvalidConfig", "FOCUS_FALLBACK 'Desktop' is not supported; using Taskbar", program, True)
            return "ahk_class Shell_TrayWnd"
    }

    return fallback
}

; Create and return an updated copy of the old window list. A new list is made from scratch and
; populated with the current windows. Timings for these windows are then copied from the old list
; if they are present, otherwise the default timeout is assigned.
updateWindowList(oldWindowList, processList)
{
    newWindowList := Map()
    for _, program in processList
    {
        newList := Map()
        for _, handle in WinGetList("ahk_exe " program)
        {
            if (oldWindowList[program].Has(handle))
                newList[handle] := oldWindowList[program][handle]
            else
                newList[handle] := Map(
                    "value", getLoops(getValue("WINDOW_TIMEOUT", program)),
                    "type", "Timeout"
                )
        }

        newWindowList[program] := newList
    }

    return newWindowList
}

; Dynamically update the System Tray icon and tooltip text, taking into consideration the number
; of windows that the script has found and the number of windows it is managing.
updateSysTray(windowList)
{
    ; Count how many windows are actively managed and how many
    ; are being monitored so we can guage the script's activity.
    managed := Map()
    monitor := Map()
    for program, windows in windowList
    {
        managed[program] := 0
        monitor[program] := 0

        for _, waitInfo in windows
        {
            if (waitInfo["type"] = "Timeout")
                monitor[program] += 1
            else if (waitInfo["type"] = "Interval")
                managed[program] += 1
        }

        if (managed[program] = 0)
            managed.Delete(program)

        if (monitor[program] = 0)
            monitor.Delete(program)
    }

    ; If windows are being managed that means the script is periodically
    ; sending input. We update the SysTray to with the number of windows
    ; that are being managed.
    if (managed.Count > 0)
    {       
        TraySetIcon(A_AhkPath, 2)

        if (monitor.Count > 0)
        {
            newTip := "Managing:`n"
            for program, windows in managed
                newTip := newTip program " - " windows "`n"

            newTip := newTip "`nMonitoring:`n"
            for program, windows in monitor
                newTip := newTip program " - " windows "`n"

            newTip := RTrim(newTip, "`n")
            newTip := appendErrorSummary(newTip)
            A_IconTip := newTip
        }
        else
        {
            newTip := "Managing:`n"
            for program, windows in managed
                newTip := newTip program " - " windows "`n"

            newTip := RTrim(newTip, "`n")
            newTip := appendErrorSummary(newTip)
            A_IconTip := newTip
        }

        return
    }

    ; If we are not managing any windows but the script is still monitoring
    ; them in case they go inactive, the SysTray is updated with the number
    ; of windows that we are watching.
    if (monitor.Count > 0)
    {      
        TraySetIcon(A_AhkPath, 3)

        newTip := "Monitoring:`n"
        for program, windows in monitor
            newTip := newTip program " - " windows "`n"

        newTip := RTrim(newTip, "`n")
        newTip := appendErrorSummary(newTip)
        A_IconTip := newTip

        return
    }

    ; If we get to this point the script is not managing or watching any windows.
    ; Essensially the script isn't doing anything and we make sure the icon conveys
    ; this if it hasn't already.
    TraySetIcon(A_AhkPath, 5)
    A_IconTip := appendErrorSummary("No windows found")
}

; Go through each window in the list and decrement it's timer.
; If the timer reaches zero the TASK function is ran and the timer is set back to it's starting value.
tickWindowList(windowList)
{
    for program, windows in windowList
    {
        for handle, timeLeft in windows
        {
            if (WinActive("ahk_id " handle))
            {
                ; If the program is active and has not timed out, we set it's timeout back to
                ; the limit. The user will need to interact with it to send it to the back and
                ; we use A_TimeIdlePhysical rather then our own timeout if it's in the foreground.
                if (A_TimeIdlePhysical < getValue("WINDOW_TIMEOUT", program) * 60000)
                {
                    timeLeft := Map(
                        "type", "Timeout",
                        "value", getLoops(getValue("WINDOW_TIMEOUT", program))
                    )

                    windowList[program][handle] := timeLeft
                    continue
                }

                ; If the program has timed out we need to update the WindowList to reflect that.
                ; We can achieve this by setting the time left to one. It will be decremented immediately
                ; afterwards and the script will activate as it sees the time left has reached zero.
                if (timeLeft["type"] = "Timeout")
                    timeLeft["value"] := 1
            }

            ; Decrement the time left, if it reaches zero reset the AFK timer. Then reset the time
            ; left and repeat.
            timeLeft["value"] -= 1
            
            if (timeLeft["value"] = 0)
            {
                timeLeft := Map(
                    "type", "Interval",
                    "value", getLoops(getValue("TASK_INTERVAL", program))
                )

                resetTimer(
                    handle,
                    getValue("TASK", program),
                    getValue("BLOCK_INPUT", program)
                )
            }

            windowList[program][handle] := timeLeft
        }
    }

    return windowList
}

updateScript()
{
    global windowList
    global PROCESS_LIST
    global updateInProgress

    if (updateInProgress)
        return

    updateInProgress := True
    try
    {
        windowList := updateWindowList(windowList, PROCESS_LIST)
        windowList := tickWindowList(windowList)

        updateSysTray(windowList)
    }
    finally
    {
        updateInProgress := False
    }
}

; Start Anti-AFK
updateScript()
SetTimer(updateScript, POLL_INTERVAL*1000)
