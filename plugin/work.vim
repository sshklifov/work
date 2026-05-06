" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

""""""""""""""""""""""""""""Commit tag"""""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#BranchIssueNumber(...)
  let branch = get(a:000, 0, git#GetBranch())
  return matchstr(branch, 'SW-[0-9]\{4\}')
endfunction

function! s:OnNewCommit()
  setlocal spell
  setlocal tw=90
  setlocal cc=91

  const whitelist = map(s:GetTargets(), 'v:val[0]')
  if index(whitelist, FugitiveWorkTree()) < 0
    return
  endif

  let branch = git#GetBranch()
  if branch == 'master' || branch == 'obsidian-master' || branch == 'main'
    return init#Warn('Current branch is %s!', branch)
  endif

  let issue = work#BranchIssueNumber()
  if empty(getline(1)) && !empty(issue)
    call setline(1, issue .. ': ')
    startinsert!
  endif
endfunction

autocmd FileType gitcommit call s:OnNewCommit()
"}}}

""""""""""""""""""""""""""""Building"""""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#GetMakeCommand()
  let repo = FugitiveWorkTree()
  let parts = split(repo, "/")
  if len(parts) > 0
    let repo = parts[-1]
    if repo == "worktree"
      let orig = git#ExecuteOrThrow(["rev-parse", "--git-common-dir"])[0]
      let repo = split(orig, "/")[-2]
    endif
  endif
  return work#GetMakeCommandFor(repo)
endfunction

function! work#GetMakeCommandFor(repo)
  if empty(a:repo)
    call init#Warn("Not inside a git tracked repo!")
  endif
  let repo = a:repo

  let dir = FugitiveWorkTree()
  if empty(dir)
    let dir = getcwd()
  endif

  let cmds = []
  call add(cmds, printf("cd %s", dir))
  call add(cmds, printf("source %s/environment-setup-armv8a-aisys-linux", g:SDK_DIR))
  if repo == 'alcatraz-ml-library'
    call add(cmds, "export ParavisionSDKType=ROCKCHIP")
  endif

  let libstdcpp = "11.5.0"
  let sdk_flags = [
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/%s/", g:SDK_DIR, libstdcpp),
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/%s/aarch64-aisys-linux", g:SDK_DIR, libstdcpp),
        \ ]
  call add(cmds, "export CXXFLAGS=" . string(join(sdk_flags)))

  if repo == 'camera_engine_rkaiq'
    let cmake = printf("cmake -S. -B%s -DCMAKE_BUILD_TYPE=%s", g:BUILD_TYPE, g:BUILD_TYPE)
    let cmake .= printf(" -DIQ_PARSER_V2_EXTRA_CFLAGS='-I%s/sysroots/armv8a-aisys-linux/usr/include/rockchip-uapi;", g:SDK_DIR)
    let cmake .= printf("-I%s/sysroots/armv8a-aisys-linux/usr/include'", g:SDK_DIR)
    let cmake .= " -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DISP_HW_VERSION='-DISP_HW_V30' -DARCH='aarch64' -DRKAIQ_TARGET_SOC='rk3588'"
  else
    let cmake = printf("cmake -B %s -S . -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_BUILD_TYPE=%s -DCMAKE_INSTALL_PREFIX=/usr", g:BUILD_TYPE, g:BUILD_TYPE)
  endif

  if repo == 'libalcatraz'
    let cmake .= " -DBUILD_TESTS=0"
    let cmake .= " -DPRELOAD_OPENCV_MAT_SUPPORT=1"
  endif
  if repo == 'alcatraz-ml-library' || repo == 'badge-and-face' || repo == 'device-health' || repo == 'libalcatraz'
    if stridx(g:DEVICE, "onyx") >= 0
      let cmake .= " -DDEVICE=onyx -DPLATFORM=obsidian"
    elseif stridx(g:DEVICE, "rockx") >= 0
      let cmake .= " -DDEVICE=obsidian -DPLATFORM=obsidian"
    endif
  endif

  if repo == 'device-health'
    let cmake .= " -DBUILD_TESTS=ON"
  endif

  " Build specific flags
  if g:BUILD_TYPE == 'Release'
    let cmake .= ' -DCMAKE_CXX_FLAGS_RELEASE="-g1 -fno-omit-frame-pointer"'
  elseif g:BUILD_TYPE == 'RelWithDebinfo'
    let cmake .= ' -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-Og -g2"'
  elseif g:BUILD_TYPE == 'Debug'
    let cmake .= ' -DCMAKE_CXX_FLAGS_DEBUG="-O0 -g -ggdb -U_FORTIFY_SOURCE"'
  endif

  let build = printf("cmake --build %s -j 10", g:BUILD_TYPE)

  let build_dir = printf("%s/%s", FugitiveWorkTree(), g:BUILD_TYPE)
  if !isdirectory(build_dir)
    call add(cmds, cmake)
  endif
  call add(cmds, build)
  let command = ["/bin/bash", "-c", join(cmds, ';')]
  return command
endfunction

command! -nargs=0 -bang Make call qutil#Make(work#GetMakeCommand(), "<bang>")

function! s:ChangeBuildType(new_type)
  " Avoids a lot of user errors
  call system(["ssh", g:HOST, printf("rm -r /%s/%s", g:RSYNC_DIR, g:BUILD_TYPE)])
  let g:BUILD_TYPE = a:new_type
endfunction

command! -nargs=0 Debug call s:ChangeBuildType("Debug")

command! -nargs=0 Release call s:ChangeBuildType("Release")

command! -nargs=0 RelWithDeb call s:ChangeBuildType("RelWithDeb")

function! s:ResolveEnvFile()
  let fname = expand("%:f")
  let resolved = ""
  if stridx(fname, "include/alcatraz") >= 0
    let idx = stridx(fname, "include/alcatraz")
    let resolved = "/home/stef/libalcatraz/" . fname[idx:]
  elseif stridx(fname, "include/rockchip") >= 0
    let basename = fnamemodify(fname, ":t")
    let resolved = "/home/stef/mpp/inc/" . basename
  elseif stridx(fname, "include/liveMedia") >= 0
    let part = matchlist(fname, 'include/liveMedia/\(.*\)')[1]
    let resolved = "/home/stef/live/liveMedia/include/" . part
  elseif stridx(fname, "include/UsageEnvironment") >= 0
    let part = matchlist(fname, 'include/UsageEnvironment/\(.*\)')[1]
    let resolved = "/home/stef/live/UsageEnvironment/include/" . part
  elseif stridx(fname, "include/BasicUsageEnvironment") >= 0
    let part = matchlist(fname, 'include/BasicUsageEnvironment/\(.*\)')[1]
    let resolved = "/home/stef/live/BasicUsageEnvironment/include/" . part
  elseif stridx(fname, "include/groupsock") >= 0
    let part = matchlist(fname, 'include/groupsock/\(.*\)')[1]
    let resolved = "/home/stef/live/groupsock/include/" . part
  elseif stridx(fname, "hiredis") >= 0
    let basename = fnamemodify(fname, ":t")
    let resolved = "/home/stef/hiredis/" .. basename
  endif

  if filereadable(resolved)
    let view = winsaveview()
    exe "edit " . resolved
    call winrestview(view)
  else
    echo "Sorry, I'm buggy, Update me! Resolved to: " . resolved
  endif
endfunction

command! -nargs=0 Clean call system("rm -rf " . FugitiveFind(g:BUILD_TYPE))
command! -nargs=0 -bang Remake exe "Clean" | exe "Make<bang>"
nnoremap <silent> <leader>env :call <SID>ResolveEnvFile()<CR>
"}}}

""""""""""""""""""""""""""""Host commands"""""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:GetJournalCmd(service_name)
  let service_path = "/usr/lib/systemd/system/" .. a:service_name
  let output = init#SystemOrThrow(["ssh", g:HOST, 'cat ' .. service_path])
  let service_name = fnamemodify(service_path, ':t:r')
  let m = matchstrlist(output, 'Description=\(.*\)', #{submatches: v:true})
  if !exists("m[0].submatches[0]")
    echo "Failed to parse description in systemd file!"
    return
  endif
  let msg = "Started " .. m[0].submatches[0] .. "."
  let cmd = printf('journalctl MESSAGE="%s" -r -o short-unix', msg)
  let output = init#SystemOrThrow(["ssh", g:HOST, cmd])

  if stridx(output[0], "No entries") < 0
    let timestamp = split(output[0])[0]
  else
    let timestamp = 0
  endif
  let output = init#SystemOrThrow(["ssh", g:HOST, 'date --date="@' .. timestamp .. '" "+%F %T"'])
  let since = output[0]
  let cmd = printf('journalctl -u %s --since="%s"', service_name, since)
  return cmd
endfunction

function! s:Journal(bang, service_name)
  let cmd = s:GetJournalCmd(a:service_name)
  if !empty(a:bang)
    sp enew
    call termopen(["ssh", g:HOST, cmd .. " -f"])
  else
    let lines = systemlist(["ssh", g:HOST, cmd])
    call init#CustomBottomBuffer('Journal ' .. a:service_name, lines)
  endif
endfunction

function! s:JournalPriority(bang, args)
  let prio = ["err", "warning", "info"]
  call qutil#CreateOneShotQuickfix(prio, "Priorities", function("s:OnPriority", [a:bang, a:args]))
endfunction

function! s:OnPriority(bang, args, prio)
  let cmd = s:GetJournalCmd(a:args)
  let cmd = printf("%s -p %s", cmd, a:prio)
  if !empty(a:bang)
    sp enew
    call termopen(["ssh", g:HOST, cmd .. " -f"])
  else
    let lines = systemlist(["ssh", g:HOST, cmd])
    call init#CustomBottomBuffer('Journal ' .. a:args, lines)
  endif
endfunction

function! JournalCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let services = s:GetServices()
  return filter(services, 'stridx(v:val, a:ArgLead) >= 0')
endfunction

command! -nargs=1 -bang -complete=customlist,JournalCompl Journal call s:Journal("<bang>", <q-args>)
command! -nargs=1 -bang -complete=customlist,JournalCompl JP call s:JournalPriority("<bang>", <q-args>)

cabbr J Journal

" TODO: Refactor health logic with selecting services (mostly for the highlight) and put into qutil#
" Then make the command open a quickfix so you select which services you want to display (good defaults)
" and when you close the window -> open the journal!

function s:ShowBootLogs()
  let cmd = ["journalctl", "-b", "--no-pager"]
  for service in s:GetServices()
    if stridx(service, "badge-and-face") < 0
      call add(cmd, "_SYSTEMD_UNIT=" .. service)
    endif
  endfor
  call add(cmd, "+")
  for prio in range(0, 4)
    call add(cmd, "PRIORITY=" .. prio)
  endfor
  call init#OnJobMaxOutput(["ssh", g:HOST, join(cmd)], 100000, "work#OnBootLogs")
endfunction

function! work#OnBootLogs(output)
  enew
  call setline(1, a:output)
  set nomodified
  set nomodifiable
  " Color warnings / errors in a separate job
  let nr = bufnr()
  let b:logs = a:output
  let b:cb_count = len(range(0, 4))
  for prio in range(0, 4)
    let cmd = ["journalctl", "-q", "-b", "--no-pager", "PRIORITY=" .. prio]
    let hl = prio < 4 ? "ErrorMsg" : "WarningMsg"
    call init#OnJobOutput(["ssh", g:HOST, join(cmd)], "work#OnBootColoredLog", nr, hl)
  endfor
endfunction

function! work#OnBootColoredLog(bufnr, hl, output)
  let ns = nvim_create_namespace('boot')
  let idx = 0
  let haystack = getbufvar(a:bufnr, "logs")
  for needle in a:output
    if !empty(needle)
      let pos = index(haystack, needle, idx)
      if pos >= 0
        call nvim_buf_set_extmark(a:bufnr, ns, pos, 0, #{line_hl_group: a:hl})
        let idx = pos + 1
      else
        call setbufvar(a:bufnr, "show_warning", v:true)
      endif
    endif
  endfor

  let count = getbufvar(a:bufnr, "cb_count") - 1
  call setbufvar(a:bufnr, "cb_count", count)
  if count == 0
    if getbufvar(a:bufnr, "show_warning")
      call init#Warn("Partial highlight.")
    endif
    call setbufvar(a:bufnr, "logs", [])
    let uptime = init#SystemOrThrow(["ssh", g:HOST, "uptime -p"])
    echo uptime[0]
  endif
endfunction

command! -nargs=0 Boot call s:ShowBootLogs()
command! -nargs=0 Uptime call s:ShowBootLogs()

function! s:SshTerminal()
  below sp
  enew
  call termopen(["ssh", g:HOST])
endfunction

command! -nargs=0 T call s:SshTerminal()

function! s:RemoteFileCommand(what, cb)
  if empty(a:what)
    let files = init#RemoteRecentFiles(g:HOST)
  else
    call system(["ssh", g:HOST, "[ -f " .. a:what .. " ]"])
    if v:shell_error
      let files = init#RemoteFindFiles(g:HOST, a:what)
    else
      let files = [a:what]
    endif
  endif
  if len(files) <= 0
    echo "Nothing to show."
  else
    call qutil#CreateOneShotQuickfix(files, 'Remote files', a:cb)
  endif
endfunction

function! work#Scp(pat)
  if !empty(a:pat)
    let files = init#RemoteFindFiles(g:HOST, a:pat)
    call qutil#CreateOneShotQuickfix(files, 'Scp', function('init#Scp', [g:HOST]))
  else
    let name = expand("%:t")
    call init#Scp(g:HOST, printf("%s/%s", g:RSYNC_DIR, name))
  endif
endfunction

function! work#SelectRemoteFile(file)
  call init#Sshfs(g:HOST, a:file)
endfunction

function! work#DownloadRemoteFile(file)
  let url = printf("%s:%s", g:HOST, a:file)
  call init#SystemOrThrow(["rsync", url, expand("~/Downloads")])
  let result = expand("~/Downloads/" .. fnamemodify(a:file, ":t"))
  if filereadable(result)
    call init#ToClipboard(result)
    let bytes = readfile(result, 'b', 200)
    for l in bytes
      if l =~# '[^\x09\x0A\x0D\x20-\x7E]'
        echo "Download " .. result
        return
      endif
    endfor
    exe "e " .. result
  endif
endfunction

function! SshfsCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return init#RemoteFindFiles(g:HOST, a:ArgLead)
endfunction

function! ScpCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return init#RemoteFindBasenames(g:HOST, a:ArgLead)
endfunction

function! RemoteExeCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let pat = "*" . a:ArgLead . "*"
  let find = printf("find %s/%s -name %s -type f -executable", g:RSYNC_DIR, g:BUILD_TYPE, shellescape(pat))
  let result = systemlist(["ssh", "-o", "ConnectTimeout=1", g:HOST, find])
  return filter(result, 'v:val !~ ".sh$"')
endfunction

function! s:OnRsyncStdout(_0, data, _1)
  for data in a:data
    let text = substitute(data, '\n', '', 'g')
    if len(text) > 0
      let m = matchlist(text, '[0-9]\+%')
      if len(m) > 0 && !empty(m[0])
        let g:statusline_dict['sync'] = m[0]
      endif
    endif
  endfor
endfunction

function! s:OnRsyncExit(post_cmds, cb, _0, code, _1)
  if a:code == 0
    if !empty(a:post_cmds)
      call init#Jobstart(["ssh" , g:HOST, a:post_cmds])
    endif
    call function(a:cb)()
  else
    echom "Sync failed!"
  endif
  let g:statusline_dict['sync'] = ''
endfunction

function! s:RemoteSyncExes(dir, exes, cb)
  let dir = a:dir
  if !isdirectory(dir) && !filereadable(dir)
    echo "Not found: " . dir
    return
  endif
  " Remove leading / or rsync will be naughty
  if dir[-1:-1] == '/'
    let dir = dir[0:-2]
  endif
  const remote_dir = g:HOST . ":" . g:RSYNC_DIR

  let cmd = ["rsync", "-rlt"]
  " Include all directories
  call add(cmd, '--include=*/')
  " Include all executables
  let post_cmds = []
  for exe in a:exes
    call add(cmd, '--include=' . exe)
    " Post cmd
    let remote_exe = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, exe)
    if exe =~ 'obsidian-video$' || exe =~ 'rock-video$'
      call add(post_cmds, "setcap cap_sys_nice+ep " .. remote_exe)
    elseif exe =~ 'mock_video$'
      call add(post_cmds, "setcap cap_kill+ep " .. remote_exe)
    endif
  endfor
  " Exclude rest. XXX: ORDER OF FLAGS MATTERS!
  call add(cmd, '--exclude=*')
  call extend(cmd, ["--info=progress2", "--out-format='%n'", dir, remote_dir])

  let OnExit = funcref("s:OnRsyncExit", [join(post_cmds, ';'), a:cb])
  call init#Jobstart(cmd, #{on_stdout: funcref("s:OnRsyncStdout"), on_exit: OnExit})
endfunction

function! s:GetSyncTargets(...)
  let pat = get(a:000, 0, '.*')
  let dir = FugitiveFind(g:BUILD_TYPE)
  let exes = systemlist(["find", dir, "-type", "f", "-executable", "-regex", pat, "-printf", "%P\n"])
  return exes
endfunction

function! s:RemoteSyncAll(dir)
  function! s:ShowSyncMessage()
    echo "Synced!"
  endfunction
  let exes = s:GetSyncTargets()
  call s:RemoteSyncExes(a:dir, exes, "s:ShowSyncMessage")
endfunction

function work#SyncOne(dir, exe)
  if exists('s:services_status')
    let systemd_name = s:GetServiceName(a:exe)
    let status = get(s:services_status, systemd_name, "inactive")
    if status != "inactive" && status != "failed"
      return init#Warn("Service %s is %s!", systemd_name, status)
    endif
  endif
  " Build clipboard string.
  let remote_exe = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, a:exe)
  " Check if there is a configured user.
  let [user, flags] = s:GetUserAndFlags(remote_exe)
  let cmd = remote_exe
  if !empty(user)
    let cmd = printf("sudo -u %s %s", user, cmd)
  endif
  if !empty(flags)
    let cmd = printf("%s %s", cmd, flags)
  endif
  call s:RemoteSyncExes(a:dir, [a:exe], function("init#ToClipboard", [cmd]))
endfunction

command! -nargs=? -complete=customlist,SyncCompl Sync
      \ call s:GetSyncTargets()->qutil#CommandPass(<q-args>)->qutil#CreateOneShotQuickfix('Sync', 'work#SyncOne', FugitiveFind(g:BUILD_TYPE))

function! SyncCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return s:GetSyncTargets()->qutil#FileCompletionPass(a:ArgLead)
endfunction

function! s:Resync()
  let dir = FugitiveFind(g:BUILD_TYPE)
  exe printf("autocmd! User MakeSuccessful ++once call s:RemoteSyncAll('%s')", dir)
  call qutil#Make(work#GetMakeCommand())
endfunction

function! work#Debug(arg, opts)
  let opts = a:opts
  const exe = split(a:arg, ' ')[0]
  let opts['exe'] = a:arg
  let opts['ssh'] = g:HOST

  " Check if there is a configured user/flags.
  let [user, flags] = s:GetUserAndFlags(exe)
  if !empty(user)
    let opts['user'] = user
  endif
  " Don't override flags set by a:arg
  if a:arg == exe && !empty(flags)
    let opts['exe'] = printf('%s %s', exe, flags)
  endif

  " Add a command to be executed once there is an inferior.
  if !has_key(opts, 'post_cmds')
    let opts['post_cmds'] = []
  endif
  let aisys_sdk_subst = printf('set substitute-path /usr/src/debug %s/sysroots/armv8a-aisys-linux/usr/src/debug', g:SDK_DIR)
  call add(opts['post_cmds'], aisys_sdk_subst)

  " Call main debugging routine.
  call init#Debug(opts)
endfunction

function! s:GetApps()
  let apps = #{
        \ rtsp-server: #{user: "rtsp-server", service: "rtsp-server.service"},
        \ badge_and_face: #{user: "badge_and_face", service: "badge-and-face.service"},
        \ qrcode-scanner: #{user: "rock-bootstrap", service:"qrcode-scanner.service"},
        \ device-health: #{user: "device-health", service: "device-health.service"},
        \ }
  if stridx(g:DEVICE, "rockx") >= 0
    let apps["obsidian-video"] = #{user: "rock-video", service: "obsidian-video.service"}
  elseif stridx(g:DEVICE, "onyx") >= 0
    let apps["rock-video"] = #{user: "rock-video", service: "rock-video.service"}
  endif
  return apps
endfunction

function! s:GetUserAndFlags(exe)
  let key = fnamemodify(a:exe, ':t')
  let apps = s:GetApps()
  if has_key(apps, key)
    let user = get(apps[key], 'user', '')
    return [user, '']
  endif
  if key == 'mock_video'
    return ['rock-video', '/tmp/capture']
  elseif key == 'capture-video'
    return ['rock-video', '-n=100']
  endif
  return ['', '']
endfunction

function! s:GetServiceName(exe)
  let key = fnamemodify(a:exe, ':t')
  return init#Get(s:GetApps(), key, 'service', '')
endfunction

function! s:RunAsService(exe)
  let remote_path = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, a:exe)
  let exe_name = fnamemodify(remote_path, ":t")
  let systemd_name = s:GetServiceName(a:exe)
  if empty(systemd_name)
    return "Unsupported: " .. exe_name
  endif
  let cmds = []
  call add(cmds, printf("echo Stopping %s...", systemd_name))
  call add(cmds, "sudo systemctl stop " .. systemd_name)
  call add(cmds, printf("sudo rsync -a --xattrs %s /usr/bin/", remote_path))
  call add(cmds, printf("echo Starting %s...", systemd_name))
  call add(cmds, "sudo systemctl start " .. systemd_name)

  sp
  enew
  let id = termopen(["ssh", g:HOST, join(cmds, ' && ')])
  call init#OnTermSuccess(id, function('s:Journal', ['!', systemd_name]))
endfunction

function! s:DetermineConfig(host, Cb)
  call init#OnJobOutput(["ssh", '-G', a:host], expand("<SID>") .. 'OnConfig', a:host, a:Cb)
endfunction

function! s:OnConfig(host, Cb, output)
  let control = filter(copy(a:output), 'v:val =~ "^controlpath"')
  if empty(control)
    call init#Warn("Control file does not exist for " .. a:host)
    let g:HOST_CONTROL = ""
  else
    let g:HOST_CONTROL = expand(split(control[0])[1])
  endif

  let ip = filter(copy(a:output), 'v:val =~ "^hostname"')
  if empty(ip)
    call init#Warn("Failed to determine IP for " .. a:host)
    let g:HOST_IP = ""
  else
    let g:HOST_IP = expand(split(ip[0])[1])
  endif

  let g:HOST = a:host
  call a:Cb()
endfunction

function! work#ControlFileExists()
  return !empty(g:HOST_CONTROL) && filereadable(g:HOST_CONTROL)
endfunction

function! work#GetHostStatus()
  return get(s:, 'control_file_exists', v:false)
endfunction

function! s:MonitorControlFile()
  call init#Jobstart("inotifywait -mq -e create,delete ~/.ssh", #{on_stdout: expand("<SID>") .. 'OnControlFileEvent'})
  call s:OnControlFileEvent()
endfunction

function! s:OnControlFileEvent(...)
  let s:control_file_exists = work#ControlFileExists()
  if !s:control_file_exists
    echom "SSH master died..."
  endif
  redrawstatus
endfunction

function! s:StartMaster()
  if work#ControlFileExists()
    call init#OnJobExit(["ssh", "-O", "check", "-S", g:HOST_CONTROL, g:HOST], function("s:OnMasterCheck"))
  else
    call s:OnRestartMaster()
  endif
endfunction

function! s:OnMasterCheck(code)
  if a:code == 0
    call s:OnMasterRunning(a:code)
  else
    call delete(g:HOST_CONTROL)
    call init#OnJobExit(["ssh", "-O", "exit", "-o", "ControlPath=" .. g:HOST_CONTROL, g:HOST], function("s:OnRestartMaster"))
  endif
endfunction

function! s:OnRestartMaster(...)
  let cmd = ["ssh", "-o", "ConnectTimeout=1", "-o", "ControlPath=" .. g:HOST_CONTROL,
        \ "-o", "ControlPersist=yes", "-o", "StrictHostKeyChecking=accept-new", "-M", "-N",
        \ g:HOST]
  call init#OnJobExit(cmd, function("s:OnMasterRunning"))
endfunction

function! s:OnMasterRunning(code)
  if a:code != 0
    call init#Warn("Failed to start SSH master!")
    return
  endif

  call s:MonitorControlFile()
  " Patch in order to avoid 'Connection reset by peer' errors.
  let fix_ssh_cmd =  'test -d /run/sshd || (mkdir -p /run/sshd && chmod 0755 /run/sshd)'
  call init#OnJobSuccess(["ssh", g:HOST, fix_ssh_cmd], function("s:OnPatchedConnection"))
endfunction

function! s:OnPatchedConnection()
  call init#OnJobOutput(["ssh", g:HOST, "mount"], function('s:OnDeviceMounts'))
  call s:DetermineRsyncDir()
  call s:DetermineSdk()
  call s:CheckMenderCommit()
  let cmd = "systemctl is-active " .. join(s:GetServices(), " ")
  call init#OnJobOutput(["ssh", g:HOST, cmd], function('s:StartServiceMonitor'))
endfunction

function! s:OnDeviceMounts(mnt)
  let mnt = filter(a:mnt, 'stridx(v:val, "on /usr ") >= 0')
  if empty(mnt)
    return
  endif
  let flags = split(matchstr(mnt[0], '([a-zA-Z,]*)')[1:-2], ",")
  if index(flags, "ro") >= 0
    call init#Jobstart(["ssh", g:HOST, "mount -o remount,rw /usr"])
  endif
endfunction

function s:DetermineSdk()
  let cmd = ["ssh", g:HOST, "cat /var/lib/mender/device_type"]
  call init#OnJobOutput(cmd, expand("<SID>") .. 'OnSdkOutput')
endfunction

function! s:OnSdkOutput(output)
  if stridx(a:output[0], "rockx-dm-p15") >= 0
    let g:DEVICE = "rockx-dm-p15"
    let g:SDK_DIR = "/opt/aisys/obsidian_p15"
  elseif stridx(a:output[0], "rockx-dm-r10") >= 0
    let g:DEVICE = "rockx-dm-r10"
    let g:SDK_DIR = "/opt/aisys/obsidian_r10"
  elseif stridx(a:output[0], "onyx-p1") >= 0
    let g:DEVICE = "onyx-p1"
    let g:SDK_DIR = "/opt/aisys/onyx_p1"
  elseif stridx(a:output[0], "onyx-cr") >= 0
    let g:DEVICE = "onyx-cr"
    let g:SDK_DIR = "/opt/aisys/onyx_cr"
  endif
  let g:objdump_exe = g:SDK_DIR .. "/sysroots/x86_64-aisdk-linux/usr/bin/aarch64-aisys-linux/aarch64-aisys-linux-objdump"
endfunction

function! s:InstallHostCommands()
  command! -nargs=? -complete=customlist,RemoteExeCompl Start call init#TryCall('work#Debug', <q-args>, #{})
  command! -nargs=? -complete=customlist,RemoteExeCompl Run call init#TryCall('work#Debug', <q-args>, #{br: init#GetDebugLoc()})
  command! -nargs=? -complete=customlist,RemoteExeCompl File call init#TryCall('work#Debug', <q-args>, #{wait: 1})

  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Attach call init#RemoteAttach('%s', <q-args>)", g:HOST)
  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Ratch call init#RemoteAttach('%s', <q-args>, v:true)", g:HOST)
  exe printf("command! -nargs=0 Ssh call init#SshTerm('%s')", g:HOST)

  command! -nargs=? -bang -complete=customlist,ScpCompl Scp call work#Scp(<q-args>)
  command! -nargs=? -complete=customlist,SshfsCompl Ssfs call s:RemoteFileCommand(<q-args>, 'work#SelectRemoteFile')
  command! -nargs=? -complete=customlist,SshfsCompl Download call s:RemoteFileCommand(<q-args>, 'work#DownloadRemoteFile')
  cabbr SSfs Ssfs

  nnoremap <silent> <leader>rb <cmd>Sync badge_and_face<CR>
  nnoremap <silent> <leader>sb <cmd>call <SID>RunAsService("bin/badge_and_face")<CR>
  nnoremap <silent> <leader>rs <cmd>Sync rtsp-server<CR>
  if stridx(g:DEVICE, "onyx") >= 0
    nnoremap <silent> <leader>rv <cmd>Sync rock-video<CR>
    nnoremap <silent> <leader>sv <cmd>call <SID>RunAsService("pipeline/rock-video")<CR>
  elseif stridx(g:DEVICE, "rockx") >= 0
    nnoremap <silent> <leader>rv <cmd>Sync obsidian-video<CR>
    nnoremap <silent> <leader>rf <cmd>Sync focus-tool<CR>
    nnoremap <silent> <leader>rq <cmd>Sync qrcode-scanner<CR>
    nnoremap <silent> <leader>sv <cmd>call <SID>RunAsService("application/obsidian-video")<CR>
  else
    call init#Warn("Not installing host specific maps!")
  endif
  nnoremap <silent> <leader>re <cmd>call <SID>Resync()<CR>
  nnoremap <silent> <leader>sdk <cmd>call <SID>FakeSdk()<CR>
endfunction

function s:OnHostChange()
  call s:InstallHostCommands()
  call s:StartMaster()
endfunction

function! HostCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let lines = readfile("/home/" .. $USER .. "/.ssh/config")
  let matches = matchstrlist(lines, 'Host \(\i\+\)$', #{submatches: v:true})
  let hosts = map(matches, "v:val.submatches[0]")
  return filter(hosts, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function! s:ChangeHost(host)
  if empty(a:host)
    echo "Current host is: " .. g:HOST
  else
    call s:DetermineConfig(a:host, function('s:OnHostResolvedIP'))
  endif
endfunction

" TODO dead code
function! s:TryReconnect(code)
  if a:code == 0
    call s:OnHostChange()
  else
    call init#Warn("Connection to '%s': Timed out.", g:HOST)
  endif
endfunction

function! s:OnHostResolvedIP()
  let cmds = []
  call add(cmds, "ssh-keygen -R " .. g:HOST_IP)
  call add(cmds, "echo 'Waiting for connection...'")
  call add(cmds, "ssh_wait_silent " .. g:HOST)

  botr split
  enew
  let id = termopen(join(cmds, ";"))
  call init#OnTermSuccess(id, expand("<SID>") .. "OnHostChange")
  startinsert
endfunction

command! -nargs=? -complete=customlist,HostCompl Host call s:ChangeHost(<q-args>)
"}}}

""""""""""""""""""""""""""""Do"""""""""""""""""""""""""""" {{{
function s:Do(cmd, ...)
  let Partial = function("s:" .. a:cmd, a:000)
  try
    call Partial()
  catch
    echo v:exception
  endtry
endfunction

function! DoCompl(ArgLead, CmdLine, CursorPos)
  let nargs = len(split(a:CmdLine))
  if a:CursorPos < len(a:CmdLine) || nargs > 2
    return []
  endif
  let cmds = ["StopServices", "DropClients", "UpdateDocker", "RunDocker", "Bb",
        \ "BuildSdk", "BuildImage", "BuildMfg", "InstallSdk", "ShowImage",
        \ "SaveImage", "InstallImage", "RefreshImage", "RefreshSdk", "Refresh",
        \ "FactoryReset", "Enroll", "HostDebugSyms", "PlotTrace", "BarfPlotTrace",
        \ "OpenCV", "MemoryMonitor", "EnableCore", "CheckHealth"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function s:GetServices()
  let services = map(values(s:GetApps()), 'v:val.service')
  call add(services, "rtsp-server-noauth.service")
  call add(services, "rtsp-server.socket")
  return services
endfunction

function! s:StopServices()
  call s:OpenServices()

  let stop_list = s:GetServices()
  let cmd = "systemctl stop"
  for service in stop_list
    let cmd ..= " " . service
  endfor

  call init#Jobstart(["ssh", g:HOST, cmd])
endfunction

function! s:DropClients()
  sp ~/obsidian-video
  Source fd_transmitter
  if search("DropClient.*Force dropped") == 0
    echo "Failed to find drop call site"
    return
  endif
endfunction

function! s:UpdateDocker()
  sp
  enew
  lcd ~/aidocker
  let cmds = ["sudo docker-compose build ubuntu22"]
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:RunDocker(...)
  sp
  enew
  lcd ~/aidocker
  let cmds = ["sudo", "docker-compose", "run", "--rm", "ubuntu22"]

  let bash_cmd = ["export USE_S3_BUCKET=1",
        \ printf("export MACHINE=%s", g:DEVICE),
        \ "source /home/stef/aidistro/setup-environment /home/stef/aicache"]
  if a:0 > 0
    call add(bash_cmd, join(a:000))
  else
    call add(bash_cmd, "/usr/bin/bash")
  endif

  let docker_cmd = printf("/usr/bin/bash -c '%s'", join(bash_cmd, ';'))
  call add(cmds, docker_cmd)
  let id = termopen(join(cmds))
  startinsert
  return id
endfunction

function! s:BuildSdk()
  return s:RunDocker("bitbake rock-image -c populate_sdk")
endfunction

function! s:BuildImage()
  return s:RunDocker("bitbake rock-image")
endfunction

function! s:BuildMfg()
  return s:RunDocker("bitbake ota-mfg-image")
endfunction

function! s:InstallSdk()
  let sdks = systemlist(["find", "/home/" .. $USER .. "/aicache/tmp/deploy/sdk/", "-regex", printf(".*%s.*.sh", g:DEVICE)])
  if empty(sdks)
    echo "No sdk found"
    return
  endif
  let most_recent_file = sdks[0]
  let most_recent_timestamp = getftime(sdks[0])
  for file in sdks[1:]
    let curr_timestamp = getftime(file)
    if curr_timestamp > most_recent_timestamp
      let most_recent_file = file
      let most_recent_timestamp = curr_timestamp
    endif
  endfor
  let mins = (localtime() - most_recent_timestamp) / 60

  split
  enew
  let cmds = []
  call add(cmds, "echo 'Found sdk from " .. mins .. "m ago'")
  call add(cmds, "rm -rf " .. g:SDK_DIR .. "/*")
  call add(cmds, printf("%s -d %s -y", most_recent_file, g:SDK_DIR))
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:FindImage()
  let images = systemlist(["find", "/home/" .. $USER .. "/aicache/tmp/deploy/images/", "-regex", printf(".*%s.*mender", g:DEVICE)])
  if empty(images)
    throw "No image found"
  endif
  let most_recent_image = images[0]
  let most_recent_timestamp = getftime(most_recent_image)
  for image in images[1:]
    let curr_timestamp = getftime(image)
    if curr_timestamp > most_recent_timestamp
      let most_recent_image = image
      let most_recent_timestamp = curr_timestamp
    endif
  endfor
  return most_recent_image
endfunction

function! s:ShowImage()
  let img = s:FindImage()
  echo img
endfunction

function! s:SaveImage(name)
  if empty(a:name)
    echo "Expecting name!"
    return
  endif
  let img = s:FindImage()
  let dest = printf("/home/%s/Downloads/%s.mender", $USER, a:name)
  call init#SystemOrThrow(printf("cp %s %s", img, dest))
  echo "Copied to " .. dest .. "."
endfunction

function! s:InstallImage()
  let most_recent_image = s:FindImage()
  let most_recent_timestamp = getftime(most_recent_image)
  let mins = (localtime() - most_recent_timestamp) / 60
  split
  enew
  let cmds = []
  call add(cmds, "echo 'Found image from " .. mins .. "m ago'")
  call add(cmds, printf("scp %s %s:%s/image.mender", most_recent_image, g:HOST, g:RSYNC_DIR))
  call add(cmds, printf("ssh %s 'mender install /%s/image.mender && reboot'", g:HOST, g:RSYNC_DIR))
  call add(cmds, "ssh_wait_silent " .. g:HOST)
  call termopen(join(cmds, " && "))
  startinsert
endfunction

function! s:RefreshImage()
  let id = s:BuildImage()
  call init#OnTermSuccess(id, function("s:InstallImage"))
endfunction

function! s:RefreshSdk()
  let id = s:BuildSdk()
  call init#OnTermSuccess(id, function("s:InstallSdk"))
endfunction

function! s:Refresh()
  let id = s:RunDocker("bitbake rock-image && bitbake rock-image -c populate_sdk")
  call init#OnTermSuccess(id, function("s:InstallBoth"))
endfunction

function! s:InstallBoth()
  call s:InstallImage()
  call s:InstallSdk()
endfunction

function! s:FakeSdk()
  let cmds = []
  let repo_dir = FugitiveWorkTree()
  if stridx(repo_dir, "libalcatraz") >= 0
    let so_name = "libalcatraz.so"
    let so_dir = printf("%s/%s/alcatraz", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/%s/libalcatraz.pc", repo_dir, g:BUILD_TYPE)
    call add(cmds, printf("rsync -rtv %s/include/alcatraz/ %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz", repo_dir, g:SDK_DIR))

    let health_api = printf("%s/include/alcatraz/health/device_health_api.h", repo_dir)
    let sdk_header_dir = printf("%s/sysroots/armv8a-aisys-linux/usr/include/alcatraz/health", g:SDK_DIR)
    call add(cmds, printf("rsync -rtv %s %s", health_api, sdk_header_dir))
  elseif stridx(repo_dir, "alcatraz-ml-library") >= 0
    let so_name = "libalcatraz_ml.so"
    let so_dir = printf("%s/%s/src", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/%s/libalcatraz_ml.pc", repo_dir, g:BUILD_TYPE)
    call add(cmds, printf("rsync -rtv %s/include/ %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz/ml", repo_dir, g:SDK_DIR))
    call add(cmds, printf("rsync -tv %s/include/rockchip/alcatraz_ml_sdk.h %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz/ml", repo_dir, g:SDK_DIR))
  elseif stridx(repo_dir, 'mpp') >= 0
    let so_name = "librockchip_mpp.so"
    let so_dir = printf("%s/%s/mpp", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/rockchip_mpp.pc", so_dir)
  elseif stridx(repo_dir, 'hiredis') >= 0
    let so_name = "libhiredis.so"
    let so_dir = printf("%s/%s", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/hiredis.pc", so_dir)
  else
    echo "No repo matched!"
    return
  endif

  " Remove old versions of the library
  call add(cmds, printf("rm %s/sysroots/armv8a-aisys-linux/usr/lib/%s*", g:SDK_DIR, so_name))
  call add(cmds, printf("rsync -Ltv %s/%s* %s/sysroots/armv8a-aisys-linux/usr/lib", so_dir, so_name, g:SDK_DIR))
  call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/share/pkgconfig", pc, g:SDK_DIR))
  call add(cmds, printf("rsync -Ltv %s/%s* %s:/usr/lib", so_dir, so_name, g:HOST))

  split
  enew
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:HostDebugSyms(...)
  let dir = g:SDK_DIR .. "/sysroots/armv8a-aisys-linux/usr/lib/.debug"
  let show_only = (a:0 == 0)
  if show_only
    let pat = ".*"
  else
    let pat = ".*" .. a:1 .. ".*"
  endif
  let files = systemlist(["find", dir, "-regex", pat])
  if !show_only
    let bytes = 0
    for file in files
      let bytes += getfsize(file)
    endfor
    let max_bytes = 300 * 1000 * 1000
    if bytes > max_bytes
      echo printf("Too many debugging symbols selected (%d vs limit %d).", bytes, max_bytes)
      call init#CustomBottomBuffer('Found objects', files)
      return
    endif

    let remote_dir = g:HOST . ":/usr/lib/.debug"
    call init#SystemOrThrow(printf("rsync -lt %s %s", join(files), remote_dir))
  endif
  call init#CustomBottomBuffer("Debug symbols", files)
endfunction

function! s:PlotTrace(name)
  if stridx(g:DEVICE, "onyx") >= 0
    let dir = "/tmp/rock-tracing"
  elseif stridx(g:DEVICE, "rockx") >= 0
    let dir = "/tmp/obsidian-profiling"
  else
    return init#Warn("Unknown device")
  endif
  let trace_txt = init#SystemOrThrow(printf("ssh %s ls -t %s", g:HOST, dir))
  if empty(trace_txt)
    echo "No trace"
    return
  endif

  let trace_txt = trace_txt[0]
  let parse_input = "~/Downloads/tracing/input/" .. a:name
  let parse_output = printf("~/Downloads/tracing/output/%s",  a:name)
  let plot_input = printf("~/Downloads/tracing/output/%s/%s", a:name, fnamemodify(trace_txt, ":r"))
  let plot_output = "~/Downloads/tracing/plot/" .. a:name

  if g:BUILD_TYPE != "Release"
    call init#Warn("Build type is %s.", g:BUILD_TYPE)
  endif

  if !isdirectory(expand("~/tracing_venv"))
    let errors = ["You do not have a python venv set up! You can run (at your own risk):"]
    call add(errors, "python -m venv tracing_venv")
    call add(errors, "source tracing_venv/bin/activate")
    call add(errors, "cd ~/libalcatraz/tracing/scripts/")
    call add(errors, "python -m pip install requirements.txt")
    return init#ShowErrors(errors)
  endif

  let cmds = []
  call add(cmds, "mkdir -p " .. parse_input)
  call add(cmds, "mkdir -p " .. plot_output)
  call add(cmds, printf("scp %s:%s/%s %s", g:HOST, dir, trace_txt, parse_input))
  call add(cmds, "source ~/tracing_venv/bin/activate")
  call add(cmds, printf("python3 parse.py -i %s -o %s", parse_input, parse_output))
  call add(cmds, printf("python3 plot_benchmark.py %s %s", plot_output, plot_input))
  botr split
  lcd ~/libalcatraz/tracing/scripts
  enew
  throw string(cmds)
  " call termopen(join(cmds, " && "), #{})
endfunction

function! s:BarfPlotTrace(name)
  let trace_txt = systemlist(printf("ssh %s ls -t /tmp | grep debug-info-", g:HOST))
  if empty(trace_txt)
    echo "No trace"
    return
  endif
  let trace_txt = trace_txt[0]

  if g:BUILD_TYPE != "Release"
    call init#Warn("Build type is %s.", g:BUILD_TYPE)
  endif

  echo "Removing extra columns from file..."
  let parse_input = "~/Downloads/bf_tracing/input/" .. a:name
  let parse_output = printf("~/Downloads/bf_tracing/output/%s",  a:name)
  let plot_input = printf("~/Downloads/bf_tracing/output/%s/%s", a:name, fnamemodify(trace_txt, ":r"))
  let plot_output = "~/Downloads/bf_tracing/plot/" .. a:name

  let cmds = []
  call add(cmds, "mkdir -p " .. parse_input)
  call add(cmds, "mkdir -p " .. plot_output)
  call add(cmds, printf("scp %s:/tmp/%s %s", g:HOST, trace_txt, parse_input))
  call init#SystemOrThrow(join(cmds, ";"))

  let local_txt = expand(printf("%s/%s", parse_input, trace_txt))
  let lines = readfile(local_txt)
  call filter(lines, 'v:val =~# " frame_id:\\| start_timestamp:\\| end_timestamp:\\|^a\\|^$"')
  call writefile(lines, local_txt)
  " Clear message status
  echo

  let cmds = []
  call add(cmds, "source ~/tracing_venv/bin/activate")
  call add(cmds, printf("python3 parse.py -i %s -o %s", parse_input, parse_output))
  call add(cmds, printf("python3 plot_benchmark.py %s %s", plot_output, plot_input))
  botr split
  lcd ~/libalcatraz/tracing/scripts
  enew
  call termopen(join(cmds, " && "), #{})
endfunction

function! s:OpenCV()
  let file = printf("~/libalcatraz/%s/memory/libalcatraz_opencv_mat.so.1.0.0", g:BUILD_TYPE)
  let file = fnamemodify(file, ":p")
  if !filereadable(file)
    echo "Preload library not found!"
    return
  endif
  let ts = localtime() - getftime(file)
  let cmds = []
  call add(cmds, printf("echo Copying over library from %dm ago", ts / 60))
  call add(cmds, printf("cp ~/libalcatraz/%s/memory/libalcatraz_opencv_mat.so* %s/sysroots/armv8a-aisys-linux/usr/lib", g:BUILD_TYPE, g:SDK_DIR))
  call add(cmds, printf("scp ~/libalcatraz/%s/memory/libalcatraz_opencv_mat.so* %s:/usr/lib", g:BUILD_TYPE, g:HOST))
  call add(cmds, printf("ssh %s chmod +s /usr/lib/libalcatraz_opencv_mat.so*", g:HOST))
  bot sp
  enew
  call termopen(join(cmds, ";"))
endfunction

function! s:MemoryMonitor(...)
  let tool = init#RemoteFindFiles(g:HOST, "backtrace_tool")
  if empty(tool)
    throw "Not found: backtrace_tool"
  endif
  let tool = tool[0]

  let input = systemlist(["ssh", g:HOST, "ls -t /tmp"])
  if empty(input)
    throw "No files found in /tmp!"
  endif
  if a:0 > 0
    call filter(input, 'stridx(v:val, a:1) >= 0')
  endif
  if empty(input)
    echo "Nothing to show!"
    return
  endif
  let input = "/tmp/" .. input[0]

  let executable = printf("%s/%s/application/obsidian-video", g:RSYNC_DIR, g:BUILD_TYPE)

  let cmd = printf("%s %s -e=%s", tool, input, executable)
  echo printf('Running tool on %s..', input)
  let lines = init#SystemOrThrow(["ssh", g:HOST, cmd])
  call init#CustomBottomBuffer('Memory report', lines)
  mode
endfunction

function! s:EnableCore()
  call init#SystemOrThrow(["ssh", g:HOST, '/usr/bin/bash -c "echo 1 > /proc/sys/fs/suid_dumpable"'])
  call init#ToClipboard("cd /tmp && ulimit -c unlimited")
endfunction

function! s:CheckHealth()
  let cmd = "redis-cli -s /run/ctlsys/redis.sock publish device-health:print 1"
  call system(["ssh", g:HOST, cmd])
endfunction

function s:GetTargets()
  " Note: Ordered by priority
  let targets = [
          \ ["/home/stef/libalcatraz", "master", "libalcatraz_git.bb"],
          \ ["/home/stef/alcatraz-ml-library", "main", "alcatraz-ml_git.bb"],
          \ ["/home/stef/device-health", "main", "device-health_git.bb"]]
  call add(targets, ["/home/stef/rock-video", "master", "rock-video_git.bb"])
  call add(targets, ["/home/stef/obsidian-video", "main", "obsidian-video_git.bb"])
  call add(targets, ["/home/stef/badge-and-face", "obsidian-master", "badge-and-face_git.bb"])
  return targets
endfunction

function! s:Bb()
  call s:AddRepo(FugitiveWorkTree())
endfunction

function! s:OpenBitbake(repo)
  let repo = a:repo
  let targets = filter(s:GetTargets(), 'v:val[0] == repo')
  if empty(targets)
    throw "Invalid repo: " .. repo
  endif

  let bitbake = targets[0][2]
  " Find old hash
  let files = qsearch#GetFiles("/home/stef/aidistro", "-regex", ".*" .. bitbake)
  if empty(files)
    throw "Could not find: " .. bitbake
  endif
  if len(files) > 1
    throw "Multiple results for : " .. bitbake
  endif
  exe "e " .. files[0]
  if search("SRCREV") == 0
    throw "Failed to find SRCREV"
  endif
endfunction

function! s:AddRepo(repo)
  let repo = a:repo
  let targets = filter(s:GetTargets(), 'v:val[0] == repo')
  if empty(targets)
    throw "Invalid repo: " .. repo
  endif

  let new_src_branch = git#GetBranch(repo)
  if empty(new_src_branch)
    throw "Failed to determine branch!"
  endif
  let new_src_rev = git#HashOrThrow(new_src_branch)

  call s:OpenBitbake(a:repo)

  call setline('.', 'SRCREV ?= "' .. new_src_rev .. '"')
  if search("SRCBRANCH") == 0
    throw "Failed to find SRCBRANCH"
  endif
  call setline('.', 'SRCBRANCH ?= "' .. new_src_branch .. '"')
  write
endfunction

function! s:FactoryReset()
  botr split
  enew
  call termopen("ssh " .. g:HOST .. " touch /run/factory-reset/initiate-reset")
endfunction

function! s:Enroll()
  let cmds = []
  call add(cmds, 'redis-cli SET config:device.role "\"one-fa\""' )
  call add(cmds, 'redis-cli SET config:enrollment.enabled true' )
  call add(cmds, 'redis-cli SET config:enrollment.min_time 5' )
  call add(cmds, 'redis-cli SET config:enrollment.respect_acs false' )
  call systemlist(["ssh", g:HOST, join(cmds, ";")])
  if !v:shell_error
    call s:SshTerminal()
    echo "Please run mcu-inject-badge!"
  endif
endfunction

command! -nargs=? -complete=customlist,HostCompl Ip call init#ToClipboard(g:HOST_IP)
cabbr IP Ip

function! s:Reboot()
  let cmds = []
  call add(cmds, printf("ssh %s reboot", g:HOST))
  call add(cmds, "echo Waiting for reboot...")
  call add(cmds, "ssh_wait_silent " .. g:HOST)
  bot sp
  enew
  call termopen(join(cmds, ";"))
endfunction

command! -nargs=0 Reboot call s:Reboot()

command -nargs=+ -complete=customlist,DoCompl Do call s:Do(<f-args>)
"}}}

""""""""""""""""""""""""""""AI"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#FetchAI()
  call git#CleanOrThrow("~/aidistro")
  e ~/aidistro

  echo "Fetching from origin..."
  call git#ExecuteOrThrow(["checkout", "master"], "Failed to checkout aidistro master")
  call git#ExecuteOrThrow(["pull", "origin", "master"], "Failed to pull aidistro")
  call git#ExecuteOrThrow(["submodule", "update", "--init", "--recursive"])
  echo "Fetching completed!"
endfunction

function! work#CommitAI()
  e ~/aidistro
  let cmd = ["diff", "--name-only", "--cached"]
  let staged = git#ExecuteOrThrow(cmd, "Cannot determine what changed in aidistro.")
  for [repo, branch, bitbake] in reverse(s:GetTargets())
    let staged_bitbake = filter(copy(staged), 'stridx(v:val, bitbake) >= 0')
    if empty(staged_bitbake)
      continue
    endif
    " Get commit message. This is needed to create the branch and the commit
    exe "e " .. repo
    let cmd = ["log", "-1", "--format=%B", "origin/" .. branch]
    let msg = git#ExecuteOrThrow(cmd, "Cannot determine commit message for " .. repo)[0]
    let issue = matchstr(msg, 'SW-[0-9]\{4\}')
    " Create branch
    e ~/aidistro
    if empty(issue)
      let ai_branch = "stef/ai"
    else
      let ai_branch = "stef/" .. issue .. "/ai"
    endif
    let cmd = ["checkout", "-b", ai_branch]
    call git#ExecuteOrThrow(cmd, "Failed to create branch " .. ai_branch)
    let ai_msg = fnamemodify(repo, ':t') .. ": " .. msg
    call git#ExecuteOrThrow(["commit", "-m", ai_msg])
    " Success
    exe "Gdrop " .. ai_branch
    return
  endfor
  throw "No changes detected!"
endfunction

function! work#TestAI()
  call s:BuildImage()
endfunction

function! work#PushAI()
  e ~/aidistro
  call git#ExecuteOrThrow(["push", "origin", "HEAD"], "Failed to push branch to origin")
  call init#ToClipboard("https://gitlab.com/Rainbe/Firmware/aidistro/-/merge_requests")
endfunction

function! work#CleanUpAI()
  e ~/aidistro
  let branch = git#GetBranchOrThrow()
  call git#ExecuteOrThrow(["checkout", "master"], "Failed to checkout master")
  " Not the end of the world if this fails.
  call git#ExecuteOrThrow(["reset", "--hard"])
  call git#ExecuteOrThrow(["pull", "origin", "master"], "Failed to pull new changes")
  call git#ExecuteOrThrow(["branch", "-D", branch], "Failed to delete newly created branch")
  let issue = matchstr(branch, 'SW-[0-9]\{4\}')
  if !empty(issue)
    call work#OpenJira(issue)
  endif
endfunction

function! work#ResetAI()
  e ~/aidistro
  call git#ExecuteOrThrow(["reset", "--hard"])
  call git#ExecuteOrThrow(["submodule", "update", "--init", "--recursive"])
  if !git#IsClean()
    echo "Failed to reset to a clean state"
    G
  endif
endfunction

function! AiCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let items = ["Fetch", "Commit", "Test", "Push", "CleanUp", "Reset"]
  return filter(items, 'v:val =~ a:ArgLead')
endfunction

command! -nargs=1 -complete=customlist,AiCompl AI call init#TryCall("work#" .. <q-args> .. "AI")
cabbr Ai AI
" }}}

""""""""""""""""""""""""""""Issue"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#OpenJira(issue)
  if !empty(a:issue)
    call init#ToClipboard("https://alcatrazai.atlassian.net/browse/" .. a:issue)
  endif
endfunction

function! work#OpenMergeRequest(arg)
  if empty(a:arg)
    call work#GenerateMergeRequestURL(FugitiveWorkTree())
  else
    call qutil#GetRepos()->qutil#CommandPass(a:arg)->qutil#CreateOneShotQuickfix("Repos", 'work#GenerateMergeRequestURL')
  endif
endfunction

function! work#GenerateMergeRequestURL(repo)
  let git_dir = a:repo .. "/.git"
  let url = git#ExecuteOrThrow([git_dir, 'remote', 'get-url', 'origin'])[0]
  let url = substitute(url, '^git@gitlab.com:', 'https://gitlab.com/', '')
  let url = substitute(url, '\.git$', '', '')
  let url ..= '/-/merge_requests'
  call init#ToClipboard(url)
endfunction

function! s:ShowActivity()
  let cmd = ["for-each-ref", "--sort=-committerdate", "refs/heads/", "--format=%(refname:short)"]
  let branches = git#ExecuteOrThrow(cmd, "Failed to fetch recent commits!")
  call filter(branches, '!empty(v:val)')
  call qutil#CreateOneShotQuickfix(branches, 'Branches', 'work#OnIssueSelected')
endfunction

function! work#OnIssueSelected(branch)
  let issue = work#BranchIssueNumber(a:branch)
  if !empty(issue)
    call work#OpenJira(issue)
  else
    echo "Nothing to show!"
  endif
endfunction

function! s:MyDashboard()
  call init#ToClipboard("https://alcatrazai.atlassian.net/jira/your-work")
endfunction

function! s:OpenCurrent()
  let issue = work#BranchIssueNumber()
  if empty(issue)
    echo "Nothing to show!"
  else
    call work#OpenJira(issue)
  endif
endfunction

function! s:CopyBranch()
  call init#ToClipboard(git#GetBranch())
endfunction

function! s:CopyHash()
  let hash = git#ExecuteOrThrow(['rev-parse', 'HEAD'], "Failed to parse HEAD")
  call init#ToClipboard(hash[0])
endfunction

function! s:MessageSearch(...)
  let args = join(a:000)
  if empty(args)
    echo "Expecting string!"
  else
    exe "G log --grep=" .. join(a:000)
  endif
endfunction

function! s:CodeSearch(...)
  let args = join(a:000)
  if empty(args)
    echo "Expecting string!"
  else
    exe "G log --all -S " .. args
  endif
endfunction

function! s:AuthorSearch(...)
  let args = join(a:000)
  if empty(args)
    let args = "Shklifov"
  endif
  exe "G log --author " .. args
endfunction

function! IssueCompl(ArgLead, CmdLine, CursorPos)
  let nargs = len(split(a:CmdLine))
  if a:CursorPos < len(a:CmdLine) || nargs > 2
    return []
  endif
  let cmds = ["ShowActivity", "MyDashboard", "OpenCurrent",
        \ "CopyBranch", "CopyHash", "MessageSearch",
        \ "CodeSearch", "AuthorSearch", "OpenMR"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

command -nargs=+ -complete=customlist,IssueCompl Issue call s:Do(<f-args>)
" }}}

""""""""""""""""""""""""""""Orientation"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:Orientation(deg)
  sp
  Ssfs /usr/share/obsidian-video/cfg/default.json
  let old_pos = search('"orientation"')
  if empty(a:deg)
    if old_pos <= 0
      echo "Orientation missing (0 degrees)."
    else
      if stridx(getline('.'), "right") >= 0
        echo "Orientation right (0 degrees)."
      elseif stridx(getline('.'), "flat") >= 0
        echo "Orientation flat (90 degrees)."
      elseif stridx(getline('.'), "left") >= 0
        echo "Orientation flat (180 degrees)."
      elseif stridx(getline('.'), "bottom") >= 0
        echo "Orientation flat (270 degrees)."
      else
        echo "Orientation unknown!"
      endif
    endif
    quit
    return
  endif

  if old_pos > 0
    call deletebufline(bufnr(), old_pos)
  endif
  let pos = search('"version"')
  if a:deg == 0
    let deg = "right"
  elseif a:deg == 90
    let deg = "flat"
  elseif a:deg == 180
    let deg = "left"
  elseif a:deg == 270
    let deg = "bottom"
  else
    echo "Invalid degrees!"
    return ''
  endif
  let config = printf('  "orientation": "%s",', deg)
  call append(pos, config)
  write
  quit
endfunction

command! -nargs=? Orientation call s:Orientation(<q-args>)
"}}}

""""""""""""""""""""""""""""Services"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:OpenServices()
  let services = s:GetServices()
  let nr = qutil#CreateCustomQuickfix(services, 'Services', expand("<SID>") .. 'OnSelectedService')
  call s:UpdateServicesHl(nr)
endfunction

function s:OnSelectedService()
  let pos = line('.')
  let service = getline(pos)
  let status = get(s:services_status, service, "")
  if status == "inactive" || status == "failed"
    call init#Jobstart(["ssh", g:HOST, "systemctl start " .. service])
  else
    let cmds = []
    if status != "active"
      call init#Warn("Status was %s.", status)
      call add(cmds, "systemctl disable " .. service)
    endif
    call add(cmds, "systemctl stop " .. service)
    call init#Jobstart(["ssh", g:HOST, join(cmds, ";")])
  endif
endfunction

function! s:StopServiceMonitor()
  if exists('s:services_job')
    if jobstop(s:services_job)
      call jobwait([s:services_job])
    endif
    unlet s:services_job
  endif
endfunction

function! s:StartServiceMonitor(initial_activity)
  call s:StopServiceMonitor()
  " XXX: Potential race condition but it makes the code look nicer so it's okay.
  let services = s:GetServices()
  let activity = filter(a:initial_activity, '!empty(v:val)')
  if len(activity) != len(services)
    " Possible if device is down.
    return init#Warn("Unknown state of some services!")
  endif
  let s:services_status = #{}
  for idx in range(len(services))
    let s:services_status[services[idx]] = activity[idx]
  endfor

  let cmd = [
        \ "dbus-monitor",
        \ "--system",
        \ string("type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.freedesktop.systemd1.Unit'")]
  let s:services_job = init#Jobstart(["ssh", g:HOST, join(cmd)], #{on_stdout: expand("<SID>") .. 'OnServicesChanged'})
endfunction

function! work#ServicesStatus()
  if !exists('s:services_status')
    echo "No services monitored!"
    return
  endif

  let lines = []
  for service in keys(s:services_status)
    let line = printf("%s: %s", service, s:services_status[service])
    call add(lines, line)
  endfor
  let nr = init#CustomBottomBuffer('Services', lines)
endfunction

function s:OnServicesChanged(_0, d, _1)
  for idx in range(len(a:d))
    let line = a:d[idx]
    if stridx(line, "path=/org/freedesktop/systemd1/unit/") >= 0
      let dbus_name = matchstr(line, 'unit/\zs[^;]*')
      let service_name = substitute(dbus_name, '_2d', '-', 'g')
      let service_name = substitute(service_name, '_2e', '.', 'g')
      let s:services_last = service_name
    elseif stridx(line, 'string "ActiveState"') >= 0
      let next_line = get(a:d, idx + 1, '')
      let activity = matchstr(next_line, 'string "\zs[^"]\+\ze"')
      " TODO DEBUG THIS BAD BOY
      if empty(activity)
        call init#Warn(next_line)
      endif
      if exists('s:services_last') && has_key(s:services_status, s:services_last)
        let changed = s:services_status[s:services_last] != activity
        if changed
          let s:services_status[s:services_last] = activity
          let nr = bufnr("Services")
          if init#IsVisible(nr)
            call s:UpdateServicesHl(nr)
          else
            call init#Warn("Service %s is %s!", s:services_last, activity)
          endif
        endif
      endif
    endif
  endfor
endfunction

function! s:UpdateServicesHl(nr)
  let services = getbufline(a:nr, 1, '$')
  let ns = nvim_create_namespace('services')
  for idx in range(len(services))
    let activity = s:services_status[services[idx]]
    let extmarks = nvim_buf_get_extmarks(a:nr, ns, [idx, 0], [idx, 0], #{details: 1})
    if !empty(extmarks)
      call nvim_buf_del_extmark(a:nr, ns, extmarks[0][0])
    endif
    if activity == 'active'
      call nvim_buf_set_extmark(a:nr, ns, idx, 0, #{line_hl_group: 'DiagnosticOk'})
    elseif activity == 'inactive'
      call nvim_buf_set_extmark(a:nr, ns, idx, 0, #{line_hl_group: 'DiagnosticUnnecessary'})
    else
      call nvim_buf_set_extmark(a:nr, ns, idx, 0, #{line_hl_group: 'Normal'})
    endif
  endfor
endfunction

command! -nargs=0 Health call s:OpenServices()
"}}}

""""""""""""""""""""""""""""RTSP"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function work#CheckRtspConnection(bang, ip)
  if !executable("nc")
    echom "nc is not executable (package netcat)"
    return
  endif
  if !empty(a:ip)
    let ip = a:ip
  else
    let ip = g:HOST_IP
  endif

  call systemlist(["ping", "-c", "1", ip])
  if v:shell_error
    return init#Warn("No connection to " .. ip)
  endif
  call system(["nc", "-w", "1", "-z", ip, 8554])
  if v:shell_error
    return init#Warn("Port 8554 is not open!")
  endif

  call system(["nc", "-w", "1", "-z", ip, 8554])

  let cmd = "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n"
  let output = systemlist(printf("timeout -p 0.1 nc %s 8554", ip), cmd)
  if stridx(join(output), "DESCRIBE") < 0
    return init#Warn("No DESCRIBE command!")
  endif

  if stridx(g:DEVICE, "onyx") >= 0
    let streams = ["ircamera", "mircamera", "depthcamera", "mdepthcamera", "rgbcamera", "mrgbcamera"]
  elseif stridx(g:DEVICE, "rockx") >= 0
    let streams = ["adaptive_h264", "adaptive_mjpeg", "near-rtsp", "far-rtsp", "center-rtsp", "intercom"]
  endif

  let cmd = ""
  let seq = 2
  for stream in streams
    let cmd .= printf("DESCRIBE rtsp://%s:8554/%s RTSP/1.0\r\n", ip, stream) .
          \ printf("CSeq: %d\r\n", seq) .
          \ "Accept: application/sdp\r\n" .
          \ "\r\n"
    let seq += 1
  endfor

  let output = system(printf("timeout -p 4 nc %s 8554", ip), cmd)
  let output = split(output, "\r\n")

  let ok = filter(copy(output), 'v:val =~# "RTSP/[0-9.]* 200 OK"')
  if empty(ok) || !empty(a:bang)
    echo printf("Found %d streams", len(ok))
    return init#CustomBottomBuffer("RTSP", output)
  endif

  let content_base = filter(copy(output), 'v:val =~# "^Content-Base:"')
  let rtpmap = filter(copy(output), 'v:val =~# "^a=rtpmap"')
  if len(ok) != len(content_base) || len(ok) != len(rtpmap)
    return init#Warn("Parse error")
  endif

  let found_streams = []
  for i in range(len(ok))
    let stream = matchstr(content_base[i], '/\zs[^/]\+\ze/\?$')
    if stridx(rtpmap[i], "H264") >= 0
      call add(found_streams, "H264: " . stream)
    elseif stridx(rtpmap[i], "JPEG") >= 0
      call add(found_streams, "MJPEG: " . stream)
    else
      call init#Warn("Unknown encoder: %s", rtpmap[i])
    endif
  endfor

  call qutil#CreateCustomQuickfix(found_streams, 'Streams', 'work#SelectStream', ip)
endfunction

function work#SelectStream(ip)
  let pos = line('.')
  let line = getline(pos)
  let [type, name] = split(line, ": ")
  if type == "H264"
    let fmt = "gst-launch-1.0 rtspsrc location=rtsp://%s:8554/%s latency=100 ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! autovideosink"
  elseif type == "MJPEG"
    let fmt = "gst-launch-1.0 rtspsrc location=rtsp://%s:8554/%s latency=0 ! rtpjpegdepay ! jpegparse ! avdec_mjpeg ! videoconvert ! autovideosink"
  endif
  let msg = printf(fmt, a:ip, name)
  call init#ToClipboard(msg)
endfunction

command! -bang -nargs=? Rtsp call work#CheckRtspConnection("<bang>", <q-args>)
"}}}

""""""""""""""""""""""""""""Check"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function s:GetRepoStatus(repo, ...)
  let repo = FugitiveExtractGitDir(a:repo)
  if !git#IsClean(repo)
    return "Dirty."
  endif

  let branch = git#GetBranch(repo)
  if empty(branch)
    return "Detached HEAD."
  endif
  if a:0 > 0 && branch != a:1
    return printf("Checked out wrong branch '%s'.", branch)
  endif

  let dict = git#ExecuteOrThrow([repo, "rev-list", "--left-right", "--count", printf("%s...origin/%s", branch, branch)])
  if dict['exit_status'] != 0
    return "Unknown remote branch!"
  endif

  let output = dict['stdout']
  if type(output) == v:t_list
    let [ahead, behind] = split(join(output))
    if ahead != 0 || behind != 0
      if ahead == 0
        return printf("Branch is %d commits behind.", behind)
      else
        return printf("Branch is %d commits behind and % commits ahead.", ahead)
      endif
    endif
  endif
  return v:null
endfunction

function s:CheckRepo(repo, ...)
  if a:0 > 0 && !empty(a:1)
    let status = s:GetRepoStatus(a:repo, a:1)
  else
    let status = s:GetRepoStatus(a:repo)
  endif
  if !empty(status)
    exe "split " .. a:repo
    let w = win_getid()
    G
    call win_execute(w, 'close')
    call nvim_echo([[status, "Normal"]], v:false, #{})
  else
    let branch = git#GetBranch(a:repo)
    echo printf("%s is clean and up to date!", branch)
  endif
endfunction

function s:ForceUpdateRepo(repo, ...)
  let repo = FugitiveExtractGitDir(a:repo)
  if a:0 > 0
    let branch = a:1
    call git#ExecuteOrThrow([repo, "reset", "--hard"])
    call git#ExecuteOrThrow([repo, "checkout", branch])
  else
    let branch = git#GetBranch(a:repo)
    if empty(branch)
      echo "Detached HEAD!"
      return
    endif
  endif

  let dict = FugitiveExecute([repo, "fetch", "origin", branch])
  if dict['exit_status'] == 0
    call git#ExecuteOrThrow([repo, "reset", "--hard", "origin/" .. branch])
  else
    call git#ExecuteOrThrow([repo, "reset", "--hard", branch])
  endif

  call git#UpdateSubmodule(repo)

  if !git#IsClean(repo)
    exe "split " .. a:repo
    let w = win_getid()
    G
    call win_execute(w, 'close')
    echo "Untracked files."
  else
    echo printf("%s is clean and up to date!", branch)
  endif
endfunction

function s:CheckAidistro(bang, branch)
  let repo = expand("~/aidistro")
  if empty(a:bang)
    call s:CheckRepo(repo, a:branch)
  elseif empty(a:branch)
    call s:ForceUpdateRepo(repo)
  else
    call s:ForceUpdateRepo(repo, a:branch)
  endif
endfunction

function! AidistroCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return git#GetRefs('refs/heads/', a:ArgLead, "~/aidistro")
endfunction

command! -bang -nargs=? -complete=customlist,AidistroCompl Aidistro call s:CheckAidistro("<bang>", <q-args>)

function! s:ShowRepoStatus(pat)
  let list = []
  let targets = add(s:GetTargets(), [expand("~/aidistro"), "master", ""])
  let targets = filter(targets, "stridx(v:val[0], a:pat) >= 0")
  for [repo, branch, _] in targets
    let status = s:GetRepoStatus(repo, branch)
    if empty(status)
      let status = "OK"
    endif
    let short_repo = fnamemodify(repo, ':t')
    call add(list, printf("%s: %s", short_repo, status))
  endfor
  call qutil#CreateCustomQuickfix(list, "Check", "work#FixRepoStatus")
endfunction

function work#FixRepoStatus()
  let line = line('.')
  let short_repo = split(getline('.'), ":")[0]
  let targets = add(s:GetTargets(), [expand("~/aidistro"), "master", ""])
  let targets = filter(targets, "stridx(v:val[0], short_repo) >= 0")
  call assert_true(len(targets) == 1)
  let [repo, branch; _] = targets[0]
  call s:ForceUpdateRepo(repo, branch)
  " Update status
  let status = s:GetRepoStatus(repo, branch)
  if empty(status)
    let status = "OK"
  endif
  call setline(line, printf("%s: %s", short_repo, status))
endfunction

command! -nargs=? -complete=customlist,CheckCompl Check call s:ShowRepoStatus(<q-args>)

function! CheckCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let repos = map(s:GetTargets(), "v:val[0]")
  call add(repos, expand("~/aidistro"))
  let repos = filter(repos, 'stridx(v:val, a:ArgLead) >= 0')
  return map(repos, 'fnamemodify(v:val, ":t")')
endfunction
"}}}

""""""""""""""""""""""""""""Mender"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function s:DetermineImage()
  let artifact = init#SystemOrThrow(["ssh", g:HOST, "mender show-artifact"])
  let commitish = matchstr(artifact[0],  '-g\([0-9a-f]\+\)')[2:]
  if empty(commitish)
    echo "Operation failed."
    return
  endif
  Repo aidistro
  let aidistro_commitish = git#HashOrThrow("HEAD")
  let len = min([len(aidistro_commitish), len(commitish)])
  if aidistro_commitish[:len-1] != commitish[:len-1]
    call init#Warn("Commit differs from ~/aidistro!")
  else
    echo "Commit matched with ~/aidistro"
  endif
  exe printf("G log %s -n 10", commitish)
  silent only
endfunction

command -nargs=0 Artifact call s:DetermineImage()
command -nargs=0 Mender call s:DetermineImage()

function s:DetermineRsyncDir()
  let cmd = "df -h --output=source,avail,target | tail +2 | sort -r -h -k2"
  call init#OnJobOutput(["ssh", g:HOST, cmd], 'work#OnDiskFree')
endfunction

function work#OnDiskFree(fs)
  let fs = filter(a:fs, '!empty(v:val)')
  " Try to auto-select the first entrry
  if !empty(fs)
    call filter(fs, 'split(v:val)[2] != "/tmp"')
    let [source, avail, target] = split(fs[0])
    const whitelist = ["/dev/shm", "/var/sync"]
    if index(whitelist, target) >= 0
      return work#OnFilesystem(fs[0])
    endif
    call qutil#CreateOneShotQuickfix(fs, "Choose RSYNC directory", "work#OnFilesystem")
  endif
endfunction

function work#OnFilesystem(entry)
  let [source, avail, target] = split(a:entry)
  let g:RSYNC_DIR = target
  if stridx(avail, "G") < 0
    call init#Warn("Have for %s RSYNC", avail)
  endif
endfunction

function s:CheckMenderCommit()
  call init#OnJobExit(["ssh", g:HOST, "test -f /var/lib/mender/upgrade_available"], 'work#OnCheckUpdate')
endfunction

function work#OnCheckUpdate(code)
  if a:code == 0
    call init#Warn("Uncommited changes with mender!")
  endif
endfunction
"}}}

""""""""""""""""""""""""""""Gitlab"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

let g:gitlab_token_file = stdpath('state') .. "/token.txt"
if filereadable(g:gitlab_token_file)
  let g:gitlab_token = readfile(g:gitlab_token_file)[0]
  let today = strftime('%Y-%m-%d')
  if today ># '2027-04-20'
    call init#Warn("Your gitlab token as expired!")
  endif
else
  call init#Warn("No gitlab token set up!")
  let g:gitlab_token = ""
endif

function! work#OnGitlabResponse(req, cb)
  let cmd = ["curl", "--silent", "--header", "PRIVATE-TOKEN:" .. g:gitlab_token, a:req]
  return init#OnJobOutput(cmd, function("s:DecodeGitlabResponse", [a:cb]))
endfunction

function! s:DecodeGitlabResponse(cb, output)
  call assert_true(len(a:output) <= 1)
  if len(a:output) >= 1
    let dict = json_decode(a:output[0])
    call function(a:cb)(dict)
  endif
endfunction

function! work#GitlabRequest(req)
  let cmd = ["curl", "--silent", "--header", "PRIVATE-TOKEN:" .. g:gitlab_token, a:req]
  return init#SystemOrThrow(cmd)
endfunction

function! work#OnGitlabUser(cb)
  if !exists('g:gitlab_user')
    call work#OnGitlabResponse("https://gitlab.com/api/v4/user", function("s:OnGitlabUser", [a:cb]))
  else
    call function(a:cb)()
  endif
endfunction

function! s:OnGitlabUser(cb, user)
  let g:gitlab_user = a:user["id"]
  call function(a:cb)()
endfunction

function! work#OpenMergeRequstQuickfix(bang)
  call work#OnGitlabUser(function("s:OnMyMergeRequests", [a:bang]))
endfunction

function! s:OnMyMergeRequests(bang)
  let field = empty(a:bang) ? "author_id" : "assignee_id"
  let req = printf("https://gitlab.com/api/v4/merge_requests?scope=all&%s=%s&state=opened&per_page=100", field, g:gitlab_user)
  call work#OnGitlabResponse(req, function("s:OnMergeRequestDict", [req]))
endfunction

function s:CompareTimestamps(lhs, rhs)
  if a:lhs.timestamp < a:rhs.timestamp
    return -1
  elseif a:lhs.timestamp > a:rhs.timestamp
    return 1
  else
    return 0
  endif
endfunction

function! s:OnMergeRequestDict(req, dict)
  const only_other_reviews = stridx(a:req, "author_id") < 0
  let list = []
  for entry in a:dict
    if only_other_reviews && entry["author"]["id"] == g:gitlab_user
      continue
    endif
    let repo = matchstr(entry["web_url"], '/\zs[^/]\+\ze/-/merge_requests')
    let targets = filter(s:GetTargets(), "stridx(v:val[0], repo) >= 0")
    let item = #{
          \ title: entry["title"],
          \ repo_id: entry["project_id"],
          \ mr_id: entry["iid"],
          \ timestamp: entry["created_at"],
          \ repo: repo,
          \ url: entry["web_url"],
          \ branch: entry["source_branch"]}
    if len(targets) >= 1
      let item["repo_full"] = targets[0][0]
    endif
    call add(list, item)
  endfor

  call sort(list, function("s:CompareTimestamps"))
  let lines = map(copy(list), "printf('[%s] %s', v:val.repo, v:val.title)")
  let nr = qutil#CreateCustomQuickfix(lines, "Gitlab", function("s:ShowMergeRequestHelp"))
  call setbufvar(nr, 'mr_list', list)
  nnoremap <silent> <buffer> B :call work#CheckMergeRequest()<CR>
  nnoremap <silent> <buffer> b :call work#CopyBranchMergeRequest()<CR>
  nnoremap <silent> <buffer> w :call work#CopyMergeRequestURL()<CR>
  nnoremap <silent> <buffer> n :call work#ShowNotesMergeRequest()<CR>
  nnoremap <silent> <buffer> T :call work#WorktreeMergeRequest()<CR>
endfunction

function s:ShowMergeRequestHelp()
  echo "(B) Reset repo to branch locally (T) Edit in worktree (b) Copy branch (w) Open URL (n) Show notes"
endfunction

function! work#CopyMergeRequestURL()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  call init#ToClipboard(entry["url"])
  " quit
endfunction

function! work#CheckMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  let repo = entry["repo_full"]
  call s:ForceUpdateRepo(repo, entry["branch"])
  quit
  exe "e " .. repo
endfunction

function! work#CopyBranchMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  call init#ToClipboard(entry["branch"])
endfunction

function! work#ShowNotesMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  let req = printf("https://gitlab.com/api/v4/projects/%s/merge_requests/%s/notes?per_page=100",
        \ entry["repo_id"], entry["mr_id"])

  let repo = entry["repo_full"]
  call work#OnGitlabResponse(req, function("s:ShowGitlabNotes", [repo]))
endfunction

function! work#WorktreeMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  let repo = entry["repo_full"]
  let branch = entry["branch"]
  let git_dir = FugitiveExtractGitDir(repo)
  call git#ExecuteOrThrow([git_dir, "fetch", "origin", branch])
  call git#TrackBranch("!", branch, git_dir)
  call git#OpenWorktree("!", branch, repo)
  " TODO MakeSuccessful -> exe "Review " .. branch
endfunction

function! s:ShowGitlabNotes(repo, resp)
  let head = git#HashOrThrow("HEAD", a:repo)
  let list = []
  for note in a:resp
    let resolvable = get(note, "resolvable", v:false)
    let resolved = get(note, "resolved", v:true)
    let text = note["body"]
    let pos = get(note, "position", #{})
    if resolvable && !resolved && !empty(pos)
      let start = pos["line_range"]["start"]
      let line = pos["new_line"]
      let file = printf("%s/%s", a:repo, pos["new_path"])
      let sha = pos["head_sha"]
      if sha != head
        let url = FugitiveFind(printf("%s:%s", sha, file))
      else
        let url = file
      endif
      let timestamp = note["created_at"]
      let author = note["author"]["username"]
      let text = printf("%s: %s", author, text)
      call add(list, #{filename: url, lnum: line, text: text, timestamp: timestamp})
    endif
  endfor
  call sort(list, function("s:CompareTimestamps"))
  call qutil#SetQuickfix(list, "Notes")
endfunction

function! s:MrCommand(bang, arg)
  if !empty(a:arg)
    if empty(a:bang)
      call work#OpenMergeRequest(a:arg)
    else
      call work#OpenMergeRequest("")
    endif
  else
    call work#OpenMergeRequstQuickfix(a:bang)
  endif
endfunction

command! -nargs=? -bang -complete=customlist,qutil#ReposCompl Mr call s:MrCommand("<bang>", <q-args>)
cabbr MR Mr

function work#OpenUnmergedBranches()
  call work#OnGitlabUser(function("s:CollectEveryMr"))
endfunction

function! s:CollectEveryMr()
  let req = printf("https://gitlab.com/api/v4/merge_requests?assignee_id=%s&state=all&&per_page=100", g:gitlab_user)
  call work#OnGitlabResponse(req, function("s:OnEveryMr"))
endfunction

function! s:OnEveryMr(dict)
  let repo_to_branch = #{}
  for entry in a:dict
    let repo = matchstr(entry["web_url"], '/\zs[^/]\+\ze/-/merge_requests')
    let targets = filter(s:GetTargets(), "stridx(v:val[0], repo) >= 0")
    if len(targets) >= 1
      let repo = targets[0][0]
      let branch = entry["source_branch"]
      if branch == "obsidian-master"
        throw string(entry)
      endif
      if !has_key(repo_to_branch, repo)
        let repo_to_branch[repo] = #{}
      endif
      let repo_to_branch[repo][branch] = 1
    endif
  endfor
  let list = []
  let current_author = git#ExecuteOrThrow(["config", "user.name"])[0]
  for repo in keys(repo_to_branch)
    let git_dir = FugitiveExtractGitDir(repo)
    let cmd = [git_dir, "for-each-ref", "--sort=-committerdate", "refs/heads/", "--format=%(refname:short)"]
    let local_branches = git#ExecuteOrThrow(cmd)
    let remote_branches = repo_to_branch[repo]
    for branch in local_branches
      let targets = filter(s:GetTargets(), "stridx(v:val[0], repo) >= 0")
      let master_branch = len(targets) >= 1 ? targets[0][1] : ""
      if !has_key(remote_branches, branch) && branch != master_branch
        let author = git#ExecuteOrThrow([git_dir, "log", branch, "-1", "--pretty=%an"])[0]
        if author == current_author
          call add(list, printf("%s: %s", repo, branch))
        endif
      endif
    endfor
  endfor
  call qutil#CreateCustomQuickfix(list, "Unmerged", function("s:OnUnmergedBranch"))
endfunction

function! s:OnUnmergedBranch()
  let line = getline('.')
  let [repo, branch] = split(line, ": ")
  call s:ForceUpdateRepo(repo, branch)
  quit
  exe "e " .. repo
endfunction

command! -nargs=0 Unmerged call work#OpenUnmergedBranches()


"}}}

function! s:OnVimEnter()
  " Install commands for the first time
  call s:OnHostChange()
  " Run RSI plugin

  " TODO -- RSI is DISABLED!
  " call RsiEnable()
endfunction

augroup Work
  autocmd! VimEnter * ++once call s:OnVimEnter()
augroup END
" }}}
