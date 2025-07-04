﻿ExecMacro(scriptText, vars, current_path) {
    if (scriptText = "")
        return
    if (runMacroCount > 10)
        return Alert("실행 중인 매크로 수가 10을 초과 합니다.")
    
    ModiKeyWait()

    UpdateMacroState(+1)
    lines := SplitLine(scriptText)

    if !IsObject(vars) {
        ShowTip("Warning! : vars is not an object")
        vars := {}
    }
    
    vars.current_path := current_path
    for index, line in lines {
        if(macroAbortRequested)
            break
        cmd := StripComments(line)
        if (cmd = "")
            continue

        ExtractVar(vars, "start_line", start_line, "natural")
        tempVars := PrepareConditionVars(cmd, vars, index, start_line)
        ; 조건 확인: force가 없고, skip_mode=vars 이며, start_line 전이면 건너뛰기
        if(tempVars._vars_skip) {
            Log("tempVars._vars_skip = true! start_line: " start_line)
            continue
        }

        cmd := ResolveCommand(cmd, vars)
        ; 조건 2: 실행 전 제어 흐름
        if (ShouldStop(vars, "wait"))
            break

        Log("tempVars.if:" tempVars.if "  Cmd: " cmd ", Line: " line)

        ; 조건 3: start_line 이후만 실행 (강제 실행 아닌 경우)
        if(tempVars._command_skip) {
            Log("tempVars._command_skip = true! start_line: " start_line)
            continue
        }
        PrepareTargetHwnd(vars)

        Loop, % vars.rep
        {
            ExecSingleCommand(cmd, vars, line, index)
            if(cmd != "" && vars.HasKey("limit")) {
                if(index = 1 || vars.limit_mode != "line")
                    vars.limit--
            }
            if (ShouldStop(vars, "delay")) 
                break
        }
        if (tempVars.HasKey("break")) {
            Log("has break current_path: " current_path "  lineNum: " index)
            break
        }
    }
    UpdateMacroState(-1)
    ; ShowTip("--- Macro End ---`n,실행중인 매크로 수 : " runMacroCount)
}

ResolveCommand(cmd, vars) {
    if (ParseKeyValueLine(cmd, vars))
        return

    vars.rep := 1

    cmd := ResolveMarkers(cmd, vars).command
    
    ; 이스케이프 복원
    ReplaceEscapeChar(cmd)
    return cmd
}

ResolveMarkers(line, vars, allowed := "", excluded := "") {
    step1 := ResolveMarker(line, vars, 1, allowed, excluded)
    step2 := ResolveExpr(step1.command, vars)
    step3 := ResolveIndexedAccess(step2, vars)
    step4 := ResolveMarker(step3, vars, 2, allowed, excluded)

    return {command: step4.command, markers: MergeMaps(step1.markers, step4.markers) }
}

PrepareConditionVars(ByRef cmd, vars, index, start_line) {
    muteAll := index < start_line
    temp := Clone(vars)

    resolved := ResolveMarkers(cmd, temp, ["force", "if", "end_if"])
    cmd := resolved.command

    if(temp.HasKey("force")) {
        muteAll := false
        temp._vars_skip := false
        temp._command_skip := false
    } 
    else if (index < start_line) {
        if (InStr(vars.skip_mode, "vars")) { ; 스킵모드가 vars 까지 모두 스킵하는경우
            temp._vars_skip := true
        } else { ; 스킵모드가 vars 는 스킵 안하는 경우
            temp._vars_skip := false
            if (!RegExMatch(cmd, "i)^Read:\s*(.+?)$")) ; Read 명령이 아니면
                temp._command_skip := true ; 명령실행 필요 없음
        }
    }
    ;if 구문 처리
    if (temp.HasKey("end_if")) {
        vars.Delete("if")
        vars.Delete("else")
    }
    ; 이번 라인에 if 문 이있으면 갱신    
    else if(resolved.markers.if) {
        temp.if := IsLogicExpr(temp.if) ? Eval(temp.if) : TryStringLogic(temp.if, temp)
        if (StrLower(temp.if) = "false")
            temp.if := false

        if (vars.if_mode = "block")
            vars.if := temp.if ; vars.if 는 if 문의 조건문 자체를 저장함
        
        vars.Delete("else")
    }
    else if(!vars.HasKey("if")) {
        temp.if := true
    }

    ; else 가 있으면 else 앞이나 뒤를 조건을 if 조건에 따라 남긴다
    if (InStr(cmd, "#else#")) {
        if(vars.else)
            Log("#else# 구문이 중복됨. cmd: " cmd)

        parts := StrSplit(cmd, "#else#", , 2)
        cmd := temp.if ? parts[1] : (parts.Length() > 1 ? parts[2] : "")

        if(vars.if_mode = "block")
            vars.else := true
    } else {
        if(vars.else)
            temp.if := !temp.if

        cmd := temp.if ? cmd : ""
    }

    ; break 파싱은 는 if 처리 후에 해야한다.
    cmd := ResolveMarkerMute(cmd, temp, 3, "break")

    if(index >= start_line)
        Log("cmd: " cmd "  if: " temp.if, 4)

    return temp
}


; 공통 key=value 추출 함수
ParseKeyValueToken(token, vars) {
    kv := StrSplit(token, "=", , 2)  ; 최대 2개로 분할
    key := Trim(kv[1])
    val := (kv.Length() = 2) ? Trim(kv[2]) : ""
    if (key != "")
        vars[key] := val
}

ReadVarsFile(path, vars) {
    fullPath := ResolveMacroFilePath(path, vars)
    if (!vars.HasKey("__Readed__"))
        vars["__Readed__"] := {}

    if (vars["__Readed__"].HasKey(fullPath))
        return

    vars["__Readed__"][fullPath] := true

    content := ReadFile(fullPath)

    ParseVars(content, vars)
    Log("ReadVarsFile(): path: " path " w3_ver: " vars.w3_ver "  _act_w3_ver: " vars._active_w3_ver)
}

ParseVars(content, vars) {
    lines := SplitLine(content)
    for index, line in lines {
        line := Trim(StripComments(line))

        if (RegExMatch(line, "i)^Read:\s*(.+?)$", m)) {
            ReadVarsFile(m1, vars)  ; 재귀 Read
            continue
        }

        kv := StrSplit(line, "=", , 2)  ; 최대 2개로 분할
        key := Trim(kv[1])
        val := (kv.Length() = 2) ? Trim(kv[2]) : ""
        if (key != "") {
            if(val && vars.w3_ver && vars._active_w3_ver && vars.w3_ver != vars._active_w3_ver)
                val := ConvertClickLine(val, vars.w3_ver, vars._active_w3_ver, vars.panel)
            vars[key] := val
        }
    }
}

ParseKeyValueLine(line, vars, delimiter := "@") {
    if (SubStr(Trim(line), 1, StrLen(delimiter)) != delimiter)
        return false

    parts := StrSplit(line, delimiter)
    for each, token in parts {
        if !token
            continue
        ParseKeyValueToken(token, vars)
    }
    return true
}

ResolveIndexedAccess(str, vars) {
    while RegExMatch(str, "vars\[\s*([^\]]*?)\s*\]", m) {
        key := Trim(m1)
        val := vars.HasKey(key) ? vars[key] : ""
        str := StrReplace(str, m, val, , 1)
    }
    return str
}

ExecSingleCommand(command, vars, line := "", index := "") {
    if RegExMatch(command, "i)^(SendRaw|Send|Chat):\s*(.*)", m) {
        cmdType := StrLower(m1), key := m2
        if(cmdType = "chat")
            Chat(key, vars.send_mode, vars.target_hwnd)
        else if(cmdType = "sendraw")
            SendKey(key, vars.send_mode . "R", vars.target_hwnd)
        else
            SendKey(key, vars.send_mode, vars.target_hwnd)
        
        Log("cmdType:" cmdType "  key: " key)
    }
    else if RegExMatch(command, "i)^(Sleep|Wait|Delay):\s*(\d*)", m) {
        vars.delay := m2
    }
    else if RegExMatch(command, "^([a-zA-Z0-9_]+)\((.*)\)$", m) {
        WinActivateWait(vars.target_hwnd)
        ExecFunc(m1, m2)
    }
    else if RegExMatch(command, "i)^Exec:\s*(.*)", m) {
        ExecMacroFile(m1, vars)
    }
    else if RegExMatch(command, "i)^Read:\s*(.*)", m) {
        ReadVarsFile(m1, vars)
    }
    else if RegExMatch(command, "i)^(Run|RunAs):\s*(.*)", m) {
        Run_(m2, StrLower(m1) = "runas")
    }
    else if RegExMatch(command, "i)^(Click|Drag):([LR])\s*(.+)", m) {
        isDrag := (StrLower(m1) = "drag")
        btn := SubStr(m2, 1, 1)
        if !(coords := ParseCoords(m3))
            return

        x1 := coords.x1, y1 := coords.y1
        x2 := coords.x2, y2 := coords.y2

        ; 좌표 변환 필요 시
        if (ShouldConvertCoords(vars)) {
            ConvertCoordInPlace(x1, y1, vars.w3_ver, vars._active_w3_ver, vars.panel)
            if (isDrag)
                ConvertCoordInPlace(x2, y2, vars.w3_ver, vars._active_w3_ver, vars.panel)
        }

        full_mode := vars.coord_mode . coords.type
        if (isDrag)
            MouseDrag(x1, y1, x2, y2, vars.target_hwnd, btn, vars.send_mode, full_mode)
        else
            SmartClick(x1, y1, vars.target_hwnd, btn, vars.send_mode, full_mode)

        Log("btn:" btn "  x: " x1 ", y: " y1, 4)
    }
    else if (command && line && index) {
        FalseTip("Error Line Num : " index " | Path: " StrReplace(vars.current_path, MACRO_DIR) " | Log:Alt+L"
              . "`nCmd: " command " | Line: " line, 5000)
    }
}

ShouldStop(vars, timeKey) {
    ;Log("timekey: " timekey " : " vars[timeKey])
    if (vars.HasKey("limit") && !IsNatural(vars.limit) || !CheckAbortAndSleep(vars[timeKey])) {
        Log("ShouldStop()")
        return true
    }
    ; timeKey 기준으로 하나만 초기화
    if (timeKey = "wait") {
        vars.wait := 0
    } else if (timeKey = "delay") {
        vars.delay := vars.HasKey("base_delay") ? vars.base_delay : BASE_DELAY
    }
    return false
}

PrepareTargetHwnd(vars) {
    ; target 있으면 가볍게 활성화만 시도
    if (vars.target && !InStr(vars.send_mode, "C"))
        WinActivateWait(vars.target), vars.Delete("target")
    
    activeHwnd := WinActive("A")

    vars.target_hwnd := activeHwnd

    ; 현재 활성 창 기준으로만 워3 버전 추적
    if (IsW3(activeHwnd) && activeHwnd != vars._last_w3_ver_hwnd) {
        vars._active_w3_ver := GetW3_Ver(activeHwnd)
        vars._last_w3_ver_hwnd := activeHwnd
    }
}

ResolveMarkerMute(line, vars, mode := 3, allowed := "", excluded := "") {
    muteAll := true
    return ResolveMarker(line, vars, mode, allowed, excluded).command
}

ResolveExprMute(line, vars) {
    muteAll := true
    return ResolveExpr(line, vars)
}

ResolveMarker(line, vars, mode := 3, allowed := "", excluded := "") {
    Log("ResolveMarker(" mode "): " line, 4)
    command := line
    markers := {}
    pos := 1

    while (found := RegExMatch(line, "(?<!#)#([^#]+)#", m, pos)) {
        fullMatch := m
        inner := Trim(m1)
        key := "",  sep := "", rawVal := ""

        ; 구문 분기
        if RegExMatch(inner, "^\s*(\w+)\s*(([:=])\s*(.*))?$", m) {
            key := m1, sep := m3, rawVal := Trim(m4)
            
            if ShouldProcessKey(key, allowed, excluded) {
                if (mode = 1 && sep = ":")
                    val := EvaluateExpr(rawVal, vars), replace := true
                else if (mode = 2 && (sep = "=" || sep = ""))
                    val := rawVal, replace := true
                else if (mode = 3)
                    val := (sep = ":") ? EvaluateExpr(rawVal, vars) : rawVal, replace := true

                if (replace) {
                    vars[key] := val
                    command := StrReplace(command, fullMatch, "", , 1)
                    markers[key] := true
                }
            }
        }
        pos := found + StrLen(fullMatch)
    }
    muteAll := false
    return { command: Trim(command), markers: markers }
}


ResolveExpr(line, vars, maxDepth := 5) {
    depth := 0
    prevLine := ""

    while (line != prevLine && depth < maxDepth) {
        prevLine := line
        pos := 1
        while (found := RegExMatch(line, "(?<!%)%([^%]+)%", m, pos)) {
            fullMatch := m
            rawExpr := Trim(m1)
            result := EvaluateExpr(rawExpr, vars)
            line := SubStr(line, 1, found - 1) . result . SubStr(line, found + StrLen(fullMatch))
            pos := found + StrLen(result)
        }
        depth++
    }
    muteAll := false
    return line
}

ReplaceEscapeChar(ByRef str) {
    str := StrReplace(str, "##", "#")
    str := StrReplace(str, "%%", "%")
}

EvaluateExpr(expr, vars) {
    ; 기본값 문법 처리
    hasDefault := false
    defaultVal := ""
    if (RegExMatch(expr, "^(.*[^|])?\|([^|].*)?$", m)) {
        expr := Trim(m1)
        defaultVal := Trim(m2)
        hasDefault := true
    }

    expr := EvaluateFunctions(expr, vars)

    ; 새 방식으로 키 치환 (안전하게)
    res := ExplodeByKeys(expr, vars)
    expr := res.expr
    isReplaced := res.isReplaced

    ; 기본값에도 동일한 키 치환 적용
    resDef := ExplodeByKeys(defaultVal, vars)
    defaultVal := resDef.expr

    ; 키 치환이 없었고, 기본값 문법이 있었다면 기본값 사용
    if (hasDefault && !isReplaced) {
        Log("default value used expr: " expr  "  defaultVal: " defaultVal)
        expr := defaultVal
    }

    return TryEval(expr, vars.dp_mode)
}

ExplodeByKeys(expr, vars) {
    result := []
    sorted := ToKeyLengthSortedArray(vars)

    ; Step 0: 큰따옴표로 감싼 문자열 보호
    ; while (found := RegExMatch(expr, """([^""]*)""", m)) {
    ;     result[found] := m
    ;     expr := StrReplace(expr, m, Dummy(m, placeHolder), , 1)
    ; }

    ; Step 1: 키워드(길이 내림차순)를 찾아 dummy로 치환하며 값 저장
    for i, item in sorted {
        while (found := RegExMatch(expr, item.key, m)) {
            is_replaced := true
            result[found] := item.value
            expr := StrReplace(expr, m, Dummy(m, placeHolder), , 1)
        }
    }

    ; Step 2: 남은 일반 문자열 처리
    while (found := RegExMatch(expr, "[^" . placeHolder . "]+", m)) {
        result[found] := m
        expr := StrReplace(expr, m, Dummy(m, placeHolder), , 1)
    }

    return {expr: StrJoin(result, ""), isReplaced: is_replaced}
}

EvaluateFunctions(expr, vars) {
    ; vars[...] 인덱스 문법 처리
    pos := 1
    while (found := RegExMatch(expr, "(\w+)\(([^)]*)\)", m, pos)) {
        full := m, fnName := m1, argStr := m2

        Log("EvaluateFunctions(): " full)

        args := StrSplit(argStr, ",")

        Loop % args.Length()
        {
            val := args[A_Index]
            val := Trim(val)
            val := ExplodeByKeys(val, vars).expr  ; 변경: 결과에서 .expr 만 사용
            args[A_Index] := TryEval(val)
        }

        result := ExecFunc(fnName, args)
        expr := StrReplace(expr, full, result)
        pos := found + StrLen(result)
    }
    return expr
}

Run_(path, isAdmin := false) {
    if(muteAll)
        return
    try {
        if (isAdmin) {
            Run *RunAs %path%
        } else {
            Run %path%
        }
    } catch e {
        MsgBox, 16, Run Failed, % "Failed to run:`n" path "`n`nError: " e.Message
    }
}

ExecFunc(fnName, argsStr) {
    fn := Func(fnName)
    if !IsObject(fn)
        return Alert("Function " fnName " not found.")

    ; argsStr가 배열이 아니라면 쉼표로 나눔
    if !IsObject(argsStr) {
        args := []
        argsStr := StrReplace(argsStr, "``,", placeHolder)
        Loop, Parse, argsStr, `,  ; 문자열로 간주하고 파싱
        {
            arg := UnescapeLiteral(Trim(A_LoopField, " `t""'"))
            args.Push(arg)
        }
    } else {
        args := argsStr  ; 이미 배열이면 그대로 사용
    }
    Log("ExecFunc(): " fnName "() args : " StrJoin(args, ", "))
    return fn.Call(args*)
}

ExecMacroFile(macroFilePath, vars) {
    fullPath := ResolveMacroFilePath(macroFilePath, vars)
    if (fullPath)
        ExecMacro(ReadFile(fullPath), vars, fullPath)
}

ResolveMacroFilePath(macroFilePath, vars) {
    AppendExt(macroFilePath)
    macroFilePath := StrReplace(macroFilePath, "/", "\")

    if (IsAbsolutePath(macroFilePath))
        return macroFilePath

    ; 상대 경로 탐색용 폴더 목록
    searchPaths := [GetContainingDir(vars.current_path), GetContainingDir(vars.base_path), MACRO_DIR, MACRO_DIR . "\common"]

    tried := [] ; 실패한 경로 로그용

    for _, basePath in searchPaths {
        tryPath := basePath . "\" . macroFilePath
        if (IsFile(tryPath))
            return tryPath

        tried.Push(tryPath)
    }

    Alert("매크로 파일을 찾을 수 없습니다.`n" . StrJoin(tried, "`n"), "Error", 0)
    return false
}

UpdateMacroState(delta) {
    runMacroCount += delta
    if (runMacroCount > 0) {
        GuiControl, macro:Text, execBtn, ■ Stop
    } else {
        GuiControl, macro:Text, execBtn, ▶ Run
        macroAbortRequested := false
        muteAll := false
        FileAppend, % logBuffer, %logFilePath%
        logBuffer := ""
    }
}

CheckAbortAndSleep(totalDelay) {
    endTime := A_TickCount + totalDelay
    while (A_TickCount < endTime) {
        if (macroAbortRequested) {
            ShowTip("매크로 중단 요청")
            return false
        }
        Sleep(Min(100, totalDelay))
        totalDelay -= 100
    }
    return !macroAbortRequested
}