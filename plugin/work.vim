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

  let branch = git#GetBranch()
  if branch == 'master' || branch == 'obsidian-master' || branch == 'main'
    return init#Warn(printf('Current branch is %s!', branch))
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
function! work#GetMakeCommand(force_configure)
  let repo = FugitiveWorkTree()
  if empty(repo)
    echo "Not inside repo"
    return
  endif
  let repo = split(FugitiveWorkTree(), "/")[-1]
  let whitelist_repos = ["obsidian-video", "libalcatraz", "mpp",
        \ "camera_engine_rkaiq", "badge-and-face", "rock-video",
        \ "alcatraz-ml-library", "mcu_manager", "sip-intercom-app",
        \ "device-health", "hiredis", "alcatraz_audio", "mcu_manager", "mcu" ]
  if index(whitelist_repos, repo) < 0
    echo "Unsupported repo: " . repo
    return []
  endif

  let cmds = []
  call add(cmds, printf("cd %s", FugitiveWorkTree()))
  call add(cmds, printf("source %s/environment-setup-armv8a-aisys-linux", g:SDK_DIR))
  if repo == 'alcatraz-ml-library'
    call add(cmds, "export ParavisionSDKType=ROCKCHIP")
  endif

  let sdk_flags = [
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.5.0/", g:SDK_DIR),
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.5.0/aarch64-aisys-linux", g:SDK_DIR), "-ffast-math", "-ftree-vectorize"]
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
    let cmake .= " -DBUILD_TESTS=0 -DPRELOAD_OPENCV_MAT_SUPPORT=1"
    if stridx(g:DEVICE, "onyx") >= 0
      let cmake .= " -DPLATFORM=onyx"
    elseif stridx(g:DEVICE, "rockx") >= 0
      let cmake .= " -DPLATFORM=obsidian-dm"
    endif
  elseif repo == 'alcatraz-ml-library' || repo == 'badge-and-face' || repo == 'device-health'
    if stridx(g:DEVICE, "onyx") >= 0
      let cmake .= " -DDEVICE=onyx"
    elseif stridx(g:DEVICE, "rockx") >= 0
      let cmake .= " -DDEVICE=obsidian"
    endif
  endif

  " Build specific flags
  if g:BUILD_TYPE == 'Release'
    let cmake .= ' -DCMAKE_CXX_FLAGS_RELEASE="-g1 -fno-omit-frame-pointer"'
  elseif g:BUILD_TYPE == 'RelWithDebinfo'
    let cmake .= ' -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-Og -g2"'
  elseif g:BUILD_TYPE == 'Debug'
    let cmake .= ' -DCMAKE_CXX_FLAGS_DEBUG="-O0 -ggdb -U_FORTIFY_SOURCE"'
  endif

  let build = printf("cmake --build %s -j 10", g:BUILD_TYPE)

  let build_dir = printf("%s/%s", FugitiveWorkTree(), g:BUILD_TYPE)
  if a:force_configure || !isdirectory(build_dir)
    call add(cmds, cmake)
  endif
  call add(cmds, build)
  let command = ["/bin/bash", "-c", join(cmds, ';')]
  return command
endfunction

command! -nargs=0 -bang Configure call qutil#Make(work#GetMakeCommand(v:true), "<bang>")
command! -nargs=0 -bang Reconfigure Configure<bang>
command! -nargs=0 -bang Make call qutil#Make(work#GetMakeCommand(v:false), "<bang>")

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
function! s:Journal(bang, arg)
  let output = init#SystemOrThrow(["ssh", g:HOST, 'cat ' .. a:arg])
  let service_name = fnamemodify(a:arg, ':t:r')
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

  if !empty(a:bang)
    sp enew
    call termopen(["ssh", g:HOST, cmd .. " -f"])
  else
    let lines = systemlist(["ssh", g:HOST, cmd])
    call init#CustomBottomBuffer('Journal ' .. service_name, lines)
  endif
endfunction

function! JournalCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let files = ["/usr/lib/systemd/system/obsidian-video.service",
        \ "/usr/lib/systemd/system/qrcode-scanner.service",
        \ "/usr/lib/systemd/system/rtsp-server-noauth.service",
        \ "/usr/lib/systemd/system/badge-and-face.service",
        \ "/usr/lib/systemd/system/rock-video.service"]
  return filter(files, 'stridx(v:val, a:ArgLead) >= 0')
endfunction

command! -nargs=1 -bang -complete=customlist,JournalCompl Journal call s:Journal("<bang>", <q-args>)

function! s:SshTerminal()
  below sp
  enew
  call termopen(["ssh", g:HOST])
endfunction

command! -nargs=0 T call s:SshTerminal()

function! s:SshfsOnSteroids(what)
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
  if len(files) > 1
    call qutil#CreateOneShotQuickfix(files, 'Remote files', 'work#SelectRemoteFile')
  elseif len(files) == 1
    call init#Sshfs(g:HOST, files[0])
  else
    echo "Nothing to show."
  endif
endfunction

function! work#SelectRemoteFile(file)
  call init#Sshfs(g:HOST, a:file)
endfunction

function! SshfsCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return init#RemoteFindFiles(g:HOST, a:ArgLead)
endfunction

function! RemoteExeCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let pat = "*" . a:ArgLead . "*"
  let find = printf("find /%s/%s -name %s -type f -executable", g:RSYNC_DIR, g:BUILD_TYPE, shellescape(pat))
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

function! s:OnRsyncExit(clipboard_str, _0, code, _1)
  if a:code == 0
    if !empty(a:clipboard_str)
      call init#ToClipboard(a:clipboard_str)
    else
      echom "Synced!"
    endif
  else
    echom "Sync failed!"
  endif
  let g:statusline_dict['sync'] = ''
endfunction

function! s:RemoteSyncExes(dir, exes, ...)
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
  for exe in a:exes
    call add(cmd, '--include=' . exe)
  endfor
  " Exclude rest. XXX: ORDER OF FLAGS MATTERS!
  call add(cmd, '--exclude=*')
  call extend(cmd, ["--info=progress2", "--out-format='%n'", dir, remote_dir])

  let clipboard_str = get(a:000, 0, "")
  call init#Jobstart(cmd, #{on_stdout: funcref("s:OnRsyncStdout"), on_exit: funcref("s:OnRsyncExit", [clipboard_str])})
endfunction

function! s:GetSyncTargets(...)
  let pat = get(a:000, 0, '.*')
  let dir = FugitiveFind(g:BUILD_TYPE)
  let exes = systemlist(["find", dir, "-type", "f", "-executable", "-regex", pat, "-printf", "%P\n"])
  return exes
endfunction

function! s:RemoteSyncAll(dir)
  let exes = s:GetSyncTargets()
  call s:RemoteSyncExes(a:dir, exes)
endfunction

function work#SyncOne(dir, exe)
  let remote_exe = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, a:exe)
  let opts = s:PrepareApp(remote_exe)
  if has_key(opts, 'user')
    let cmd = printf("sudo -u %s %s", opts['user'], opts['exe'])
  else
    let cmd = opts['exe']
  endif
  call s:RemoteSyncExes(a:dir, [a:exe], cmd)
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
  call qutil#Make(work#GetMakeCommand(v:false))
endfunction

" command -nargs=0 -bang Capability let g:CAPABILITIES = <bang>1

function s:MakeNiceApp(exe)
  if get(g:, 'CAPABILITIES', 1)
    let exe = split(a:exe, " ")[0]
    call init#SystemOrThrow(["ssh" , g:HOST, "setcap cap_sys_nice+ep " .. exe])
  else
    call init#Warn("Capabilities are disabled!")
  endif
  return a:exe
endfunction

function! s:PrepareApp(exe)
  if a:exe =~ "qrcode-scanner$"
    return #{exe: a:exe, user: "rock-bootstrap"}
  elseif a:exe =~ "rock-video$"
    return #{exe: a:exe, user: "rock-video"}
  elseif a:exe =~ "device-health$"
    return #{exe: a:exe, user: "device-health"}
  endif
  let nice_exe = s:MakeNiceApp(a:exe)
  if a:exe =~ "rtsp-server$"
    let nice_exe ..= " --noauth"
    return #{exe: nice_exe, user: "rtsp-server"}
  elseif a:exe =~ "badge_and_face$"
    return #{exe: nice_exe, user: "badge_and_face"}
  elseif a:exe =~ "profile_generator$"
    return #{exe: nice_exe}
  elseif a:exe =~ 'obsidian-video$'
    return #{exe: nice_exe, user: "rock-video"}
  else
    return #{exe: nice_exe}
  endif
endfunction

function! work#Debug(exe, opts)
  let opts = extend(a:opts, s:PrepareApp(a:exe))
  " TODO hacky code
  let opts['exe'] = a:exe
  let opts['ssh'] = g:HOST
  if !has_key(opts, 'post_cmds')
    let opts['post_cmds'] = []
  endif
  let aisys_sdk_subst = printf('set substitute-path /usr/src/debug %s/sysroots/armv8a-aisys-linux/usr/src/debug', g:SDK_DIR)
  call add(opts['post_cmds'], aisys_sdk_subst)
  call init#Debug(opts)
endfunction

function! work#Start(exe)
  call work#Debug(a:exe, #{})
endfunction

function! work#Run(exe)
  call work#Debug(a:exe, #{br: init#GetDebugLoc()})
endfunction

function! work#File(exe)
  call work#Debug(a:exe, #{wait: 1})
endfunction

function! s:AppToClipboard(app)
  let app = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, a:app)
  let opts = s:PrepareApp(app)
  if has_key(opts, 'user')
    let cmd = printf("sudo -u %s %s", opts['user'], opts['exe'])
  else
    let cmd = opts['exe']
  endif
  " Sanity check
  if exists('s:services_status')
    let systemd_name = s:AppServiceFile(a:app)
    let status = get(s:services_status, systemd_name, "inactive")
    if status != "inactive" && status != "failed"
      return init#Warn(printf("Service %s is %s!", systemd_name, status))
    endif
  endif
  call init#ToClipboard(cmd)
endfunction

function! s:AppServiceFile(app)
  let exe_name = fnamemodify(a:app, ':t')
  if exe_name == 'obsidian-video'
    return "obsidian-video.service"
  elseif exe_name == 'badge_and_face'
    return 'badge-and-face.service'
  elseif exe_name == 'rock-video'
    return 'rock-video.service'
  endif
  return ''
endfunction

function! s:AppToSystemd(app)
  let app = printf("/%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, a:app)
  let exe_name = fnamemodify(app, ":t")
  let systemd_name = s:AppServiceFile(app)
  if empty(systemd_name)
    return "Unsupported app: " .. a:app
  endif
  let cmds = []
  call add(cmds, printf("echo Stopping %s...", systemd_name))
  call add(cmds, "systemctl stop " .. systemd_name)
  call add(cmds, printf("cp %s /usr/bin/%s", app, exe_name))
  call add(cmds, "setcap cap_sys_nice+ep /usr/bin/" .. exe_name)
  call add(cmds, printf("echo Starting %s...", systemd_name))
  call add(cmds, "systemctl start " .. systemd_name)

  sp
  enew
  let id = termopen(["ssh", g:HOST, join(cmds, ' && ')])
  let systemd_file = JournalCompl(systemd_name, '', 0)
  if len(systemd_file) == 1
    call init#OnTermClosed(id, function('s:Journal', ['!', systemd_file[0]]))
  else
    call init#Warn('Failed to find ' .. systemd_name)
  endif
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
  if init#IsMainWorkspace()
    return work#IsMasterRunning()
  else
    return get(s:, 'control_file_exists', v:false)
  endif
endfunction

function! s:MonitorControlFile()
  call init#Jobstart("inotifywait -mq -e create,delete ~/.ssh", #{on_stdout: expand("<SID>") .. 'OnControlFileEvent'})
  call s:OnControlFileEvent()
endfunction

function! s:OnControlFileEvent(...)
  let s:control_file_exists = work#ControlFileExists()
  if s:control_file_exists
    call s:DetermineSdk()
  else
    echom "SSH connection died..."
  endif
  redrawstatus!
endfunction

function! work#IsMasterRunning()
  return get(s:, 'master_job_id', 0) > 0
endfunction

function! s:StartMaster()
  if exists('s:master_job_id')
    call timer_stop(s:master_timer_id)
    if jobstop(s:master_job_id)
      call jobwait([s:master_job_id])
    endif
  endif
  call assert_false(work#ControlFileExists())

  let cmd = "ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=accept-new -N -M " .. g:HOST
  let s:master_job_id = init#OnJobExit(cmd, expand("<SID>") .. 'OnMasterExit')
  let s:master_timer_id = timer_start(1100, 's:CheckMasterConnection')
  call assert_true(s:master_job_id > 0)
endfunction

function! s:OnMasterExit(code)
  if !exists('s:master_retries')
    let s:master_retries = 0
  endif
  let s:master_retries += 1

  unlet s:master_job_id
  redrawstatus!


  const max_retries = 5
  if s:master_retries <= max_retries
    echom printf("SSH master died! Retrying %d/%d...", s:master_retries, 5)
    call init#OnJobSuccess("ssh_wait_silent " .. g:HOST, expand("<SID>") .. 'StartMaster')
  else
    call init#Warn("REACHED THE MAXIMUM NUMBER OF SSH MASTER RETRIES!")
  endif
endfunction

function! s:CheckMasterConnection(...)
  if work#IsMasterRunning()
    redrawstatus!
    call s:OnConnectedMaster()
  endif
endfunction

function s:OnConnectedMaster()
  call s:DetermineSdk()
  call init#OnJobOutput(["ssh", g:HOST, "mount"], function('s:OnDeviceMounts'))
  let cmd = "systemctl is-active " .. join(work#GetServices(), " ")
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
endfunction

function! s:InstallHostCommands()
  command! -nargs=? -complete=customlist,RemoteExeCompl Start call init#TryCall('work#Start', <q-args>)
  command! -nargs=? -complete=customlist,RemoteExeCompl Run call init#TryCall('work#Run', <q-args>)
  command! -nargs=? -complete=customlist,RemoteExeCompl File call init#TryCall('work#File', <q-args>)

  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Attach call init#RemoteAttach('%s', <q-args>)", g:HOST)
  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Ratch call init#RemoteAttach('%s', <q-args>, v:true)", g:HOST)
  exe printf("command! -nargs=0 Ssh call init#SshTerm('%s')", g:HOST)
  exe printf("command! -nargs=? -bang Sshfind call init#RemoteRecentFiles('<bang>', '%s', <q-args>)", g:HOST)
  exe printf("command! -nargs=? -complete=customlist,SshfsCompl Scp call init#Scp('%s', empty(<q-args>) ? '/tmp' : <q-args>)", g:HOST)

  command! -nargs=? -complete=customlist,SshfsCompl Ssfs call s:SshfsOnSteroids(<q-args>)
  cabbr SSfs Ssfs

  nnoremap <silent> <leader>rb <cmd>call <SID>AppToClipboard("bin/badge_and_face")<CR>
  nnoremap <silent> <leader>sb <cmd>call <SID>AppToSystemd("bin/badge_and_face")<CR>
  if stridx(g:DEVICE, "onyx") >= 0
    nnoremap <silent> <leader>rv <cmd>call <SID>AppToClipboard("pipeline/rock-video")<CR>
    nnoremap <silent> <leader>rs <cmd>call <SID>AppToClipboard("pipeline/rtsp-server")<CR>
    nnoremap <silent> <leader>sv <cmd>call <SID>AppToSystemd("pipeline/rock-video")<CR>
  elseif stridx(g:DEVICE, "rockx") >= 0
    nnoremap <silent> <leader>rv <cmd>call <SID>AppToClipboard("application/obsidian-video")<CR>
    nnoremap <silent> <leader>rf <cmd>call <SID>AppToClipboard("application/focus-tool")<CR>
    nnoremap <silent> <leader>rq <cmd>call <SID>AppToClipboard("application/qrcode-scanner")<CR>
    nnoremap <silent> <leader>rs <cmd>call <SID>AppToClipboard("application/rtsp-server")<CR>
    nnoremap <silent> <leader>sv <cmd>call <SID>AppToSystemd("application/obsidian-video")<CR>
  else
    call init#Warn("Not installing host specific maps!")
  endif
  nnoremap <silent> <leader>re <cmd>call <SID>Resync()<CR>
  nnoremap <silent> <leader>sdk <cmd>call <SID>FakeSdk()<CR>
endfunction

function s:OnHostChange()
  call s:InstallHostCommands()
  if init#IsMainWorkspace()
    call s:StartMaster()
  else
    call s:MonitorControlFile()
  endif
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

" TODO Trust

function s:ChangeHost(host)
  if empty(a:host)
    echo "Current host is: " .. g:HOST
  else
    call s:DetermineConfig(a:host, function('s:OnHostChange'))
  endif
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
        \ "OpenCV", "MemoryMonitor", "EnableCore"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function work#GetServices()
  let services = [
        \ "rtsp-server-noauth.service",
        \ "rtsp-server.socket",
        \ "rtsp-server.service",
        \ "badge-and-face.service",
        \ "qrcode-scanner.service",
        \ "device-health.service",
        \ ]
  if stridx(g:DEVICE, "rockx") >= 0
    call add(services, "obsidian-video.service")
  elseif stridx(g:DEVICE, "onyx") >= 0
    call add(services, "rock-video.service")
  endif
  return services
endfunction

function! s:StopServices()
  let stop_list = work#GetServices()
  let cmds = []
  for service in stop_list
    let cmd = "systemctl stop " . service
    call add(cmds, cmd)
  endfor

  call init#SystemOrThrow(["ssh", g:HOST, join(cmds, ";")])
  echo "Stopped."
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
  call add(cmds, printf("scp %s %s:/tmp/image.mender", most_recent_image, g:HOST))
  call add(cmds, printf("ssh %s 'mender install /tmp/image.mender && reboot'", g:HOST))
  call add(cmds, "ssh_wait_silent " .. g:HOST)
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:RefreshImage()
  let id = s:BuildImage()
  call init#OnTermClosed(id, function("s:InstallImage"))
endfunction

function! s:RefreshSdk()
  let id = s:BuildSdk()
  call init#OnTermClosed(id, function("s:InstallSdk"))
endfunction

function! s:Refresh()
  let id = s:RunDocker("bitbake rock-image && bitbake rock-image -c populate_sdk")
  call init#OnTermClosed(id, function("s:InstallBoth"))
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
  elseif stridx(repo_dir, 'csdblib') >= 0
    let so_name = "libcsdb.so"
    let so_dir = printf("%s/%s", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/libcsdb.pc", so_dir)
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
  let trace_txt = systemlist(printf("ssh %s ls -t /tmp/obsidian-trace/", g:HOST))
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
    let msg = "Build type is " .. g:BUILD_TYPE .. "."
    call init#Warn(msg)
  endif

  let cmds = []
  call add(cmds, "mkdir -p " .. parse_input)
  call add(cmds, "mkdir -p " .. plot_output)
  call add(cmds, printf("scp %s:/tmp/obsidian-trace/%s %s", g:HOST, trace_txt, parse_input))
  call add(cmds, "source ~/tracing_venv/bin/activate")
  call add(cmds, printf("python3 parse.py -i %s -o %s", parse_input, parse_output))
  call add(cmds, printf("python3 plot_benchmark.py %s %s", plot_output, plot_input))
  botr split
  lcd ~/libalcatraz/tracing/scripts
  enew
  call termopen(join(cmds, " && "), #{})
endfunction

function! s:BarfPlotTrace(name)
  let trace_txt = systemlist(printf("ssh %s ls -t /tmp | grep debug-info-", g:HOST))
  if empty(trace_txt)
    echo "No trace"
    return
  endif
  let trace_txt = trace_txt[0]

  if g:BUILD_TYPE != "Release"
    let msg = "Build type is " .. g:BUILD_TYPE .. "."
    call init#Warn(msg)
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

function s:GetTargets()
  " Note: Ordered by priority
  let targets = [
          \ ["/home/stef/libalcatraz", "master", "libalcatraz_git.bb"],
          \ ["/home/stef/alcatraz-ml-library", "main", "alcatraz-ml_git.bb"],
          \ ["/home/stef/device-health", "main", "device-health_git.bb"]]
  if stridx(g:DEVICE, "onyx") >= 0
    call add(targets, ["/home/stef/rock-video", "master", "rock-video_git.bb"])
    call add(targets, ["/home/stef/badge-and-face", "master", "badge-and-face_git.bb"])
  elseif stridx(g:DEVICE, "rockx") >= 0
    call add(targets, ["/home/stef/obsidian-video", "main", "obsidian-video_git.bb"])
    call add(targets, ["/home/stef/badge-and-face", "obsidian-master", "badge-and-face_git.bb"])
  else
    throw "Unknown device: " .. g:DEVICE
  endif
  return targets
endfunction

function! s:Bb()
  call s:AddRepo(FugitiveWorkTree())
endfunction

" TODO Da e po avtomatizirano pls
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
  if new_src_branch != targets[0][1]
    call init#Warn('Branch differs from mainline.')
  endif

  let new_src_rev = git#HashOrThrow(new_src_branch)
  let bitbake = targets[0][2]
  " Find old hash
  let id = qsearch#Find("/home/stef/aidistro", "-regex", ".*" .. bitbake)
  call jobwait([id])
  if search("SRCREV") == 0
    throw "Failed to find SRCREV"
  endif
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

function! s:CopyGstH264Str()
  " let mjpeg_msg = "gst-launch-1.0 rtspsrc location=rtsp://%s:8554/adaptive_mjpeg latency=0 ! rtpjpegdepay ! jpegparse ! avdec_mjpeg ! videoconvert ! autovideosink"
  let h264_msg = "gst-launch-1.0 rtspsrc location=rtsp://%s:8554/adaptive_h264 latency=100 ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! autovideosink"
  call init#ToClipboard(printf(h264_msg, g:HOST_IP))
endfunction

function! s:CopyGstMjpegStr()
  let mjpeg_msg = "gst-launch-1.0 rtspsrc location=rtsp://%s:8554/adaptive_mjpeg latency=0 ! rtpjpegdepay ! jpegparse ! avdec_mjpeg ! videoconvert ! autovideosink"
  call init#ToClipboard(printf(mjpeg_msg, g:HOST_IP))
endfunction

command! -nargs=0 H264 call s:CopyGstH264Str()
command! -nargs=0 Mjpeg call s:CopyGstMjpegStr()

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
        \ "CodeSearch", "AuthorSearch"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

command -nargs=+ -complete=customlist,IssueCompl Issue call s:Do(<f-args>)
" }}}

""""""""""""""""""""""""""""Disas"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#Disassemble(dyn, arg)
  let exe = a:arg
  let funcs = systemlist(printf("nm -g%s --defined-only %s", a:dyn, exe))
  call map(funcs, 'split(v:val)')
  call filter(funcs, 'toupper(v:val[1]) == "W" || toupper(v:val[1]) == "T"')
  call map(funcs, 'v:val[2]')
  if empty(funcs)
    echo "No symbols!"
    return
  endif
  let unmangled = systemlist("c++filt", funcs)
  call map(unmangled, 'v:val[:180]')
  let nr = qutil#CreateCustomQuickfix(unmangled, 'Symbols', 'work#SelectSymbol', exe)
  if nr >= 0
    " Much faster than binding it in above 'function'.
    let b:mangled_names = funcs
    call setbufvar(nr, '&modifiable', v:false)
  endif
endfunction

function! work#SelectSymbol(exe)
  let idx = line('.') - 1
  let mangled = b:mangled_names[idx]

  let objdump = g:SDK_DIR .. "/sysroots/x86_64-aisdk-linux/usr/bin/aarch64-aisys-linux/aarch64-aisys-linux-objdump"
  let disas = systemlist(printf('%s -Sl --disassemble=%s %s', objdump, mangled, a:exe))

  let disas_nr = bufadd('Disassembly')
  call setbufvar(disas_nr, '&buftype', 'nofile')
  call setbufvar(disas_nr, '&bufhidden', 'wipe')
  call bufload(disas_nr)

  let file_line_map = #{}
  let curr_lines = []
  for i in range(len(disas))
    let m = matchlist(disas[i], '^\(/.*\):\([0-9]\+\)')
    if !empty(m)
      let curr_file = m[1]
      " Needed in order to get syntax (init#CopySyntax)
      exe "e " .. curr_file
      let curr_lines = getline(1, '$')
      let curr_pos = 0
    else
      let m = matchlist(disas[i], '^\s*\x\+:')
      if !empty(m)
        call init#AppendChunksAtEnd(disas_nr, [[disas[i], '@module']])
      elseif !empty(curr_lines)
        let idx = index(curr_lines[curr_pos:], disas[i])
        if idx >= 0
          let curr_pos += idx + 1
          call init#CopySyntax(curr_pos, disas_nr)
          if !has_key(file_line_map, curr_file)
            let file_line_map[curr_file] = #{}
          endif
          let line_map = file_line_map[curr_file]
          if !has_key(line_map, curr_pos - 1)
            let line_map[curr_pos - 1] = []
          endif
          call add(line_map[curr_pos - 1], nvim_buf_line_count(disas_nr) - 1)
        else
          let curr_lines = []
        endif
      endif
    endif
  endfor

  call setbufvar(disas_nr, '&expandtab', v:false)
  call setbufvar(disas_nr, '&smarttab', v:false)
  call setbufvar(disas_nr, '&softtabstop', 0)
  call setbufvar(disas_nr, '&tabstop', 8)
  call setbufvar(disas_nr, 'file_line_map', file_line_map)

  for filename in keys(file_line_map)
    " Needed by LSP to process file
    exe "e " .. filename
    let nr = bufnr()
    exe printf("lua GetSemanticTokens(%d, 'work#TransferExtmarks', {%d, %d})", nr, disas_nr, nr)
  endfor

  quit
  exe "b " .. disas_nr
  call setbufvar(disas_nr, '&list', v:false)
endfunction

function work#TransferExtmarks(dst_nr, src_nr, in_lnum, in_col, in_opt)
  let ns = nvim_create_namespace('semantic_tokens')
  let file_line_map = getbufvar(a:dst_nr, 'file_line_map')
  let src_pathname = fnamemodify(bufname(a:src_nr), ':p')
  let line_map = file_line_map[src_pathname]
  if has_key(line_map, a:in_lnum)
    let dst_lnums = line_map[a:in_lnum]
    for dst_lnum in dst_lnums
      call nvim_buf_set_extmark(a:dst_nr, ns, dst_lnum, a:in_col, a:in_opt)
    endfor
  endif
endfunction

function! s:GetDisassembleTargets()
  let dir = FugitiveWorkTree()
  if !isdirectory(dir)
    return []
  endif
  let dir = printf("%s/%s", dir, g:BUILD_TYPE)
  return systemlist(["find", dir, "-type", "f", "-executable"])
endfunction

command! -nargs=? -bang -complete=customlist,DisassembleCompl Disassemble
      \ call s:GetDisassembleTargets()->qutil#CommandPass(<q-args>)->qutil#CreateOneShotQuickfix('Disassemble', 'work#Disassemble', <bang>0 ? 'D' : '')

function! DisassembleCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return s:GetDisassembleTargets()->qutil#FileCompletionPass(a:ArgLead)
endfunction
"}}}

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
  " call init#SystemOrThrow(["ssh", g:HOST, "systemctl restart obsidian-video"])
endfunction

command! -nargs=? Orientation call s:Orientation(<q-args>)
"}}}

""""""""""""""""""""""""""""Services"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:OpenServices()
  let did_start = !exists('s:services_job')
  if did_start
    let cmd = "systemctl is-active " .. join(work#GetServices(), " ")
    let activity = systemlist(["ssh", g:HOST, cmd])
    call s:StartServiceMonitor(activity)
  endif
  let services = work#GetServices()
  let nr = qutil#CreateCustomQuickfix(services, 'Services', expand("<SID>") .. 'OnSelectedService')
  call s:UpdateServicesHl(nr)
  if did_start
    call assert_false(init#IsMainWorkspace())
    call init#OnBufDelete(nr, expand("<SID>") .. "StopServiceMonitor")
  endif
endfunction

function s:OnSelectedService()
  let pos = line('.')
  let service = getline(pos)
  let status = get(s:services_status, service, "")
  if status == "inactive"
    call init#Jobstart(["ssh", g:HOST, "systemctl start " .. service])
  else
    let cmds = []
    if status != "active"
      call init#Warn("Status was " .. status .. ".")
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
  let services = work#GetServices()
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

function s:OnServicesChanged(_0, d, _1)
  for idx in range(len(a:d))
    let line = a:d[idx]
    if stridx(line, "path=/org/freedesktop/systemd1/unit/") >= 0
      let dbus_name = matchstr(line, 'unit/\zs[^;]*')
      let service_name = substitute(dbus_name, '_2d', '-', 'g')
      let service_name = substitute(service_name, '_2e', '.', 'g')
      if index(work#GetServices(), service_name) >= 0
        let s:services_last = service_name
      endif
    elseif stridx(line, 'string "ActiveState"') >= 0
      let next_line = get(a:d, idx + 1, '')
      let activity = matchstr(next_line, 'string "\zs[^"]\+\ze"')
      if exists('s:services_last') && s:services_status[s:services_last] != activity
        let s:services_status[s:services_last] = activity
        let nr = bufnr("Services")
        if init#IsVisible(nr)
          call s:UpdateServicesHl(nr)
        else
          call init#Warn(printf("Service %s is %s!", s:services_last, activity))
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

function! s:OnVimEnter()
  " Install commands for the first time
  call s:OnHostChange()
  " Run RSI plugin
  if init#IsMainWorkspace()
    call RsiEnable()
  endif
endfunction

augroup Work
  autocmd! VimEnter * ++once call s:OnVimEnter()
augroup END
" }}}
