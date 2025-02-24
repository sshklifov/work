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
function s:ObsidianMake(...)
  let repo = FugitiveWorkTree()
  if empty(repo)
    echo "Not inside repo"
    return
  endif
  let repo = split(FugitiveWorkTree(), "/")[-1]
  let whitelist_repos = ["obsidian-video", "libalcatraz", "mpp",
        \ "camera_engine_rkaiq", "badge-and-face", "rock-video",
        \ "alcatraz-ml-library", "mcu_manager", "sip-intercom-app",
        \ "badge-and-face-rock" ]
  if index(obsidian_repos, repo) < 0
    echo "Unsupported repo: " . repo
    return
  endif

  let common_flags = [
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.4.0/", g:SDK_DIR),
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.4.0/aarch64-aisys-linux", g:SDK_DIR)]
  if g:BUILD_TYPE == "Debug"
    let common_flags += ["-O0", "-ggdb", "-U_FORTIFY_SOURCE"]
  else
    let common_flags += ["-O2", "-g1"]
  endif
  let common_flags = join(common_flags)

  let cmds = []
  call add(cmds, printf("cd %s", FugitiveWorkTree()))
  call add(cmds, printf("source %s/environment-setup-armv8a-aisys-linux", g:SDK_DIR))
  if repo == 'alcatraz-ml-library'
    call add(cmds, "export ParavisionSDKType=ROCKCHIP")
  endif
  call add(cmds, "export CXXFLAGS=" . string(common_flags))
  call add(cmds, "export CFLAGS=" . string(common_flags))

  if repo == 'camera_engine_rkaiq'
    let cmake = printf("cmake -S. -B%s -DCMAKE_BUILD_TYPE=%s", g:BUILD_TYPE, g:BUILD_TYPE)
    let cmake .= printf(" -DIQ_PARSER_V2_EXTRA_CFLAGS='-I%s/sysroots/armv8a-aisys-linux/usr/include/rockchip-uapi;", g:SDK_DIR)
    let cmake .= printf("-I%s/sysroots/armv8a-aisys-linux/usr/include'", g:SDK_DIR)
    let cmake .= " -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DISP_HW_VERSION='-DISP_HW_V30' -DARCH='aarch64' -DRKAIQ_TARGET_SOC='rk3588'"
  else
    let cmake = printf("cmake -B %s -S . -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_BUILD_TYPE=%s -DCMAKE_INSTALL_PREFIX=/usr", g:BUILD_TYPE, g:BUILD_TYPE)
  endif
  let build = printf("cmake --build %s -j 10", g:BUILD_TYPE)

  call add(cmds, cmake)
  call add(cmds, build)
  let command = ["/bin/bash", "-c", join(cmds, ';')]

  let bang = get(a:, 1, "")
  return Make(command, bang)
endfunction

command! -nargs=? -complete=customlist,BuildCompl Debug let g:BUILD_TYPE = "Debug"

command! -nargs=? -complete=customlist,BuildCompl Release let g:BUILD_TYPE = "Release"

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
  endif

  if filereadable(resolved)
    let view = winsaveview()
    exe "edit " . resolved
    call winrestview(view)
  else
    echo "Sorry, I'm buggy, Update me! Resolved to: " . resolved
  endif
endfunction

command! -nargs=0 -bang Make call <SID>ObsidianMake("<bang>")
command! -nargs=0 -bang Remake exe "Clean" | exe "Make<bang>"
command! -nargs=0 Clean call system("rm -rf " . FugitiveFind(g:BUILD_TYPE))
nnoremap <silent> <leader>env :call <SID>ResolveEnvFile()<CR>
"}}}

""""""""""""""""""""""""""""Host commands"""""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:Journal(bang, arg)
  let output = systemlist(["ssh", g:HOST, 'cat ' .. a:arg])
  if v:shell_error
    call init#ShowErrors(output)
    return
  endif
  let service_name = fnamemodify(a:arg, ':t:r')
  let m = matchstrlist(output, 'Description=\(.*\)', #{submatches: v:true})
  if !exists("m[0].submatches[0]")
    echo "Failed to parse description in systemd file!"
    return
  endif
  let msg = "Started " .. m[0].submatches[0] .. "."
  let output = systemlist(["ssh", g:HOST, printf('journalctl MESSAGE="%s" -r -o short-unix', msg)])
  if v:shell_error
    call init#ShowErrors(output)
    return
  endif

  if stridx(output[0], "No entries") < 0
    let timestamp = split(output[0])[0]
  else
    let timestamp = 0
  endif
  let output = systemlist(["ssh", g:HOST, 'date --date="@' .. timestamp .. '" "+%F %T"'])
  if v:shell_error
    call init#ShowErrors(output)
    return
  endif
  let since = output[0]
  let cmd = printf('journalctl -u %s --since="%s"', service_name, since)

  if !empty(a:bang)
    sp enew
    call termopen(["ssh", g:HOST, cmd .. " -f"])
  else
    let lines = systemlist(["ssh", g:HOST, cmd])
    let nr = init#CreateCustomBuffer('Journal ' .. service_name, lines)
    sp
    exe "b " .. nr
  endif
endfunction

function! JournalCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let files = ["/usr/lib/systemd/system/obsidian-video.service",
        \ "/usr/lib/systemd/system/qrcode-scanner.service",
        \ "/usr/lib/systemd/system/badge-and-face.service",
        \ "/usr/lib/systemd/system/rock-video.service"]
  return filter(files, 'stridx(v:val, a:ArgLead) >= 0')
endfunction

command! -nargs=1 -bang -complete=customlist,JournalCompl Journal call s:Journal("<bang>", <q-args>)

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
    call init#CreateCustomQuickfix('Remote files', files, 'work#SelectRemoteFile')
  elseif len(files) == 1
    call init#Sshfs(g:HOST, files[0])
  else
    echo "Nothing to show."
  endif
endfunction

function! work#SelectRemoteFile()
  let file = getline('.')
  quit
  call init#Sshfs(g:HOST, file)
endfunction

function! SshfsCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return init#RemoteFindFiles(g:HOST, a:ArgLead)
endfunction

function! RemoteExeCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine) || g:BUILD_TYPE == "Release"
    return []
  endif
  let pat = "*" . a:ArgLead . "*"
  let find = "find /var/tmp/Debug -name " . shellescape(pat) . " -type f -executable"
  let result = systemlist(["ssh", "-o", "ConnectTimeout=1", g:HOST, find])
  return filter(result, 'v:val !~ ".sh$"')
endfunction

function! s:RemoteSync(arg, ...)
  function! OnStdout(id, data, event)
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

  function! OnExit(id, code, event)
    if a:code == 0
      echom "Synced!"
    else
      echom "Sync failed!"
    endif
    let g:statusline_dict['sync'] = ''
  endfunction

  let dir = a:arg
  if !isdirectory(dir) && !filereadable(dir)
    echo "Not found: " . dir
    return
  endif
  " Remove leading / or rsync will be naughty
  if dir[-1:-1] == '/'
    let dir = dir[0:-2]
  endif
  const remote_dir = g:HOST . ":/var/tmp/"

  let cmd = ["rsync", "-rlt"]

  let pat = get(a:000, 0, "")
  let pat = empty(pat) ? ".*" : printf(".*%s.*", pat)
  " Include all directories
  call add(cmd, '--include=*/')
  " Include all executables
  let exes = systemlist(["find", dir, "-type", "f", "-executable", "-regex", pat, "-printf", "%P\n"])
  for exe in exes
    call add(cmd, '--include=' . exe)
  endfor
  " Exclude rest. XXX: ORDER OF FLAGS MATTERS!
  call add(cmd, '--exclude=*')

  call extend(cmd, ["--info=progress2", dir, remote_dir])
  return jobstart(cmd, #{on_stdout: funcref("OnStdout"), on_exit: funcref("OnExit")})
endfunction

command! -nargs=? Sync call s:RemoteSync(FugitiveFind(g:BUILD_TYPE), <q-args>)

function! s:Resync()
  let dir = FugitiveFind(g:BUILD_TYPE)
  let pat = ".*"
  if stridx(dir, "obsidian-video") > 0
    let pat = "obsidian-video"
  elseif stridx(dir, "badge-and-face") > 0
    let pat = "badge_and_face"
  elseif stridx(dir, "libalcatraz") > 0
    let pat = ""
  endif
  if !empty(pat)
    exe printf("autocmd! User MakeSuccessful ++once call s:RemoteSync('%s', '%s')", dir, pat)
  endif
  call s:ObsidianMake()
endfunction

" command -nargs=0 -bang Capability let g:CAPABILITIES = <bang>1

function s:MakeNiceApp(exe)
  if get(g:, 'CAPABILITIES', 1)
    let exe = split(a:exe, " ")[0]
    let msg = systemlist(["ssh" , g:HOST, "setcap cap_sys_nice+ep " .. exe])
    if v:shell_error
      call init#ShowErrors(msg)
      throw "Failed to prepare " . exe
    endif
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
  endif
  let nice_exe = s:MakeNiceApp(a:exe)
  if a:exe =~ "rtsp-server$"
    let nice_exe ..= " --noauth"
    return #{exe: nice_exe, user: "rtsp-server"}
  elseif a:exe =~ "badge_and_face$"
    return #{exe: nice_exe, user: "badge_and_face"}
  elseif a:exe =~ "profile_generator$"
    return #{exe: nice_exe}
  else
    return #{exe: nice_exe, user: "rock-video"}
  endif
endfunction

function! work#Debug(exe, opts)
  let opts = extend(a:opts, s:PrepareApp(a:exe))
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
  let app = printf("/var/tmp/%s/%s", g:BUILD_TYPE, a:app)
  let opts = s:PrepareApp(app)
  if has_key(opts, 'user')
    let cmd = printf("sudo -u %s %s", opts['user'], opts['exe'])
  else
    let cmd = opts['exe']
  endif
  call init#ToClipboard(cmd)
endfunction

function! s:AppToSystemd(app)
  let app = printf("/var/tmp/%s/%s", g:BUILD_TYPE, a:app)
  let name = fnamemodify(app, ':t')
  if name == 'obsidian-video'
    let systemd_name = "obsidian-video"
  elseif name == 'badge_and_face'
    let systemd_name = 'badge-and-face'
  elseif name == 'rock-video'
    let systemd_name = 'rock-video'
  else
    echo "Unsupported app: " .. a:app
    return
  endif

  let cmds = []
  call add(cmds, printf("echo Stopping %s...", systemd_name))
  call add(cmds, "systemctl stop " .. systemd_name)
  call add(cmds, printf("cp %s /usr/bin/%s", app, name))
  call add(cmds, "setcap cap_sys_nice+ep /usr/bin/" .. name)
  call add(cmds, printf("echo Starting %s...", systemd_name))
  call add(cmds, "systemctl start " .. systemd_name)

  sp
  enew
  let id = termopen(["ssh", g:HOST, join(cmds, ' && ')])
  let systemd_file = JournalCompl(systemd_name, '', 0)
  if len(systemd_file) == 1
    call init#OnJobFinished(id, function('s:Journal', ['!', systemd_file[0]]))
  else
    call init#Warn('Failed to find ' .. systemd_name)
  endif
endfunction

function! s:ControlFileExists()
  let config = systemlist(["ssh", '-G', g:HOST])
  call filter(config, 'v:val =~ "^controlpath"')
  let path = expand(split(config[0])[1])
  return filereadable(path)
endfunction

function! s:StopMaster()
  if exists('s:master_job_id')
    if jobstop(s:master_job_id)
      call jobwait([s:master_job_id])
    endif
  endif
  return !s:ControlFileExists()
endfunction

function! s:StartMaster()
  if !s:StopMaster()
    return v:false
  endif
  let cmd = ["ssh", "-o", "ConnectTimeout=1", "-N", "-M", g:HOST]
  let id = jobstart(cmd, #{on_exit: 's:OnMasterExit'})
  if id <= 0
    echoerr "Failed to start SSH master!"
    return v:false
  endif
  let s:master_job_id = id
  return v:true
endfunction

function! s:OnMasterExit(...)
  if !exists('s:no_died_message')
    echom "SSH master died!"
  endif
  unlet s:master_job_id
endfunction

function! work#IsMasterRunning()
  return get(s:, 'master_job_id', 0) > 0
endfunction

function s:DetermineSdk()
  let lines = systemlist(["ssh", g:HOST, "cat /var/lib/mender/device_type"])
  if v:shell_error
    return v:false
  endif
  if stridx(lines[0], "rockx-dm-p15") >= 0
    let g:DEVICE = "rockx-dm-p15"
    let g:SDK_DIR = "/opt/aisys/obsidian_p15"
    return v:true
  elseif stridx(lines[0], "rockx-dm-r10") >= 0
    let g:DEVICE = "rockx-dm-r10"
    let g:SDK_DIR = "/opt/aisys/obsidian_r10"
    return v:true
  elseif stridx(lines[0], "onyx-p1") >= 0
    let g:DEVICE = "onyx-p1"
    let g:SDK_DIR = "/opt/aisys/onyx_p1"
    return v:true
  elseif stridx(lines[0], "onyx-cr") >= 0
    let g:DEVICE = "onyx-cr"
    let g:SDK_DIR = "/opt/aisys/onyx_cr"
    return v:true
  endif
  return v:false
endfunction

function! s:InstallHostCommands()
  command! -nargs=? -complete=customlist,RemoteExeCompl Start call init#TryCall('work#Start', <q-args>)
  command! -nargs=? -complete=customlist,RemoteExeCompl Run call init#TryCall('work#Run', <q-args>)
  command! -nargs=? -complete=customlist,RemoteExeCompl File call init#TryCall('work#File', <q-args>)

  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Attach call init#RemoteAttach('%s', <q-args>)", g:HOST)
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

function! s:ChangeHost(host, tried_to_trust)
  let host = empty(a:host) ? "max_p15" : a:host
  call system(["ssh", "-o", "ConnectTimeout=1", host, "exit"])
  if v:shell_error != 0
    " Yikes recursion???
    if !a:tried_to_trust
      let id = s:Trust(host)
      call init#OnJobFinished(id, function('s:ChangeHost', [a:host, v:true]))
    else
      call init#Warn("Failed to connect to host " . host)
    endif
    return
  endif

  let old_host = g:HOST
  try
    let g:HOST = host
    call s:InstallHostCommands()
    if !s:StartMaster()
      throw "Failed to restart SSH master!"
    endif
    if !s:DetermineSdk()
      throw "Failed to determine SDK! You must manually set g:DEVICE"
    endif
    mode
    echo "SSH master restarted."
  catch
    let g:HOST = old_host
    call s:InstallHostCommands()
    call s:StartMaster()
    mode
    echom v:exception
    return
  endtry
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

command! -nargs=? -complete=customlist,HostCompl Host call s:ChangeHost(<q-args>, v:false)
"}}}

""""""""""""""""""""""""""""DO"""""""""""""""""""""""""""" {{{
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
  let cmds = ["StopServices", "DropClients", "UpdateDocker", "RunDocker",
        \ "BuildSdk", "BuildImage", "InstallSdk", "ShowImage",
        \ "InstallImage", "RefreshImage", "RefreshSdk", "Refresh",
        \ "FakeSdk", "FakeMpp", "FakeImage", "ReverseImage",
        \ "FactoryReset", "Trust", "HostDebugSyms", "PlotTrace",
        \ "BarfPlotTrace", "MemoryMonitor", "EnableCore"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function! s:StopServices()
  let stop_list = [
        \ "rtsp-server-noauth",
        \ "rtsp-server.socket",
        \ "rtsp-server.service",
        \ "badge-and-face",
        \ "qrcode-scanner",
        \ "obsidian-video"
        \ ]
  if stridx(g:DEVICE_TYPE, "rockx") >= 0
    call add(stop_list, "obsidian-video")
  elseif stridx(g:DEVICE_TYPE, "onyx") >= 0
    call add(stop_list, "rock-video")
  endif

  let cmds = []
  for service in stop_list
    let cmd = "systemctl stop " . service
    call add(cmds, cmd)
  endfor

  let msg = systemlist(["ssh", g:HOST, join(cmds, ";")])
  if v:shell_error
    bot new
    setlocal buftype=nofile
    call setline(1, msg[0])
    call append(1, msg[1:])
    throw "Failed to stop services"
  endif
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
  lcd ~/aidistro
  let cmds = ["sudo docker-compose build ubuntu22"]
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:RunDocker(...)
  sp
  enew
  lcd ~/aidistro
  let cmds = ["sudo", "docker-compose", "run", "--rm", "ubuntu22"]

  let bash_cmd = ["export USE_S3_BUCKET=1",
        \ printf("export MACHINE=%s", g:DEVICE),
        \ "source /home/stef/aidistro/setup-environment /home/stef/cache"]
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

function! s:InstallSdk()
  let sdks = systemlist(["find", "/home/" .. $USER .. "/aidistro/cache/tmp/deploy/sdk/", "-regex", printf(".*%s.*dev.sh", g:DEVICE)])
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
  let images = systemlist(["find", "/home/" .. $USER .. "/aidistro/cache/tmp/deploy/images/", "-regex", printf(".*%s.*mender", g:DEVICE)])
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
  call init#OnJobFinished(id, function("s:InstallImage"))
endfunction

function! s:RefreshSdk()
  let id = s:BuildSdk()
  call init#OnJobFinished(id, function("s:InstallSdk"))
endfunction

function! s:Refresh()
  let id = s:RunDocker("bitbake rock-image && bitbake rock-image -c populate_sdk")
  call init#OnJobFinished(id, function("s:InstallBoth"))
endfunction

function! s:InstallBoth()
  call s:InstallImage()
  call s:InstallSdk()
endfunction

function! s:FakeSdk()
  let cmds = []
  let repo_dir = $HOME .. "/libalcatraz"
  let so_pattern = printf("%s/%s/alcatraz/libalcatraz.so*", repo_dir, g:BUILD_TYPE)
  call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/lib", so_pattern, g:SDK_DIR))
  let pc_pattern = printf("%s/%s/libalcatraz.pc", repo_dir, g:BUILD_TYPE)
  call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/share/pkgconfig", pc_pattern, g:SDK_DIR))
  call add(cmds, printf("rsync -rtv %s/include/alcatraz/ %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz", repo_dir, g:SDK_DIR))
  call add(cmds, printf("rsync -Ltv %s %s:/usr/lib", so_pattern, g:HOST))

  split
  enew
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:FakeMpp()
  let cmds = []
  let repo_dir = $HOME .. "/mpp"
  let so_pattern = printf("%s/%s/mpp/librockchip_mpp.so*", repo_dir, g:BUILD_TYPE)
  call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/lib", so_pattern, g:SDK_DIR))
  call add(cmds, printf("rsync -Ltv %s %s:/usr/lib", so_pattern, g:HOST))

  split
  enew
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:HostDebugSyms(pat)
  let dir = g:SDK_DIR .. "/sysroots/armv8a-aisys-linux/usr/lib/.debug"
  let pat = ".*" .. a:pat .. ".*"
  let files = systemlist(["find", dir, "-regex", pat])
  let bytes = 0
  for file in files
    let bytes += getfsize(file)
  endfor
  let max_bytes = 300 * 1000 * 1000
  if bytes > max_bytes
    echo printf("Too many debugging symbols selected (%d vs limit %d).", bytes, max_bytes)
    return
  endif

  let remote_dir = g:HOST . ":/usr/lib/.debug"
  let msg = systemlist(printf("rsync -lt %s %s", join(files), remote_dir))
  if v:shell_error
    call init#ShowErrors(msg)
  else
    botr split
    enew
    let so = map(files, "fnamemodify(v:val, ':t')")
    call setline(1, so)
    set nomodified
    echo "Debug symbols installed!"
  endif
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
  let output = systemlist(join(cmds, ";"))
  if v:shell_error
    call init#ShowErrors(output)
    throw "Failed to obtain debug info"
  endif

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

function! s:MemoryMonitor()
  let tool = init#RemoteFindFiles(g:HOST, "backtrace_tool")
  if empty(tool)
    throw "Not found: backtrace_tool"
  endif
  let tool = tool[0]

  let input = systemlist(["ssh", g:HOST, "ls -t /tmp"])
  if empty(input)
    throw "No files found in /tmp!"
  endif
  let input = "/tmp/" .. input[0]

  let executable = printf("/var/tmp/%s/bin/badge_and_face", g:BUILD_TYPE)

  let cmd = printf("%s %s -e=%s", tool, input, executable)
  echo printf('Running tool on %s..', input)
  let lines = systemlist(["ssh", g:HOST, cmd])
  if v:shell_error
    echo 'Errors encountered!'
  else
    let nr = init#CreateCustomBuffer('Memory report', lines)
    bot sp
    exe "b " .. nr
    mode
  endif
endfunction

function! s:EnableCore()
  let output = systemlist(["ssh", g:HOST, '/usr/bin/bash -c "echo 1 > /proc/sys/fs/suid_dumpable"'])
  if v:shell_error
    call init#ShowErrors(output)
  else
    echo "suid_dumpable set to true."
  endif
endfunction

function! s:FakeImage()
  let targets = [
        \ ["~/libalcatraz", "master", "libalcatraz_git.bb"],
        \ ["~/obsidian-video", "main", "obsidian-video_git.bb"],
        \ ["~/badge-and-face", "obsidian-master", "badge-and-face-obsidian_git.bb"]]

  for [repo, branch, bitbake] in targets
    " Find new hash
    exe "e " .. repo
    call git#CleanOrThrow()

    " Check if unpushed
    let new_branch = git#GetBranch()
    if empty(new_branch)
      throw "Repo " .. repo .. " does not have a branch!"
    endif
    let new_hash = git#HashOrThrow(new_branch)
    if new_hash != git#HashOrThrow("origin/" .. new_branch)
      let msg = "You have unpushed changes in " .. repo
      call init#Warn(msg)
    endif

    " Find old hash
    let id = QuickFind("~/aidistro/repo", "-regex", ".*" .. bitbake)
    call jobwait([id])
    if search("SRCREV") == 0
      throw "Failed to find SRCREV"
    endif
    call setline('.', 'SRCREV ?= "' .. new_hash .. '"')
    if search("SRCBRANCH") == 0
      throw "Failed to find SRCBRANCH"
    endif
    call setline('.', 'SRCBRANCH ?= "' .. new_branch .. '"')
    write
  endfor
  " Display changes
  e ~/aidistro/repo
  G
  exe "normal \<C-w>w"
  q
endfunction

function! s:ReverseImage()
  let targets = [
        \ ["~/libalcatraz", "master", "libalcatraz_git.bb"],
        \ ["~/obsidian-video", "main", "obsidian-video_git.bb"],
        \ ["~/badge-and-face", "obsidian-master", "badge-and-face-obsidian_git.bb"]]

  for [repo, branch, bitbake] in targets
    " Find hash
    sp
    let id = QuickFind("~/aidistro/repo", "-regex", ".*" .. bitbake)
    call jobwait([id])
    if search("SRCREV") == 0
      throw "Failed to find SRCREV"
    endif
    let hash = matchstr(getline('.'), '\x\{10,}')
    q
    " Checkout hash
    exe "tabnew " .. repo
    call git#ExecuteOrThrow(['checkout', hash], "Failed to checkout in " .. repo)
    exe "G log"
  endfor
endfunction

function! s:FactoryReset()
  botr split
  enew
  call termopen("ssh " .. g:HOST .. " touch /run/factory-reset/initiate-reset")
endfunction

function! s:GetIp(...)
  let host = get(a:000, 0, "")
  if str2nr(host) > 0
    let ip = "10.1.20." .. host
  else
    if empty(host)
      let host = g:HOST
    endif
    let ssh_config = systemlist(["ssh", "-G", host])
    call filter(ssh_config, 'v:val =~ "^hostname"')
    let ip = split(ssh_config[0])[1]
  endif
  return ip
endfunction

function! s:CopyIp(args)
  let ip = s:GetIp(a:args)
  call init#ToClipboard(ip)
endfunction

command! -nargs=? -complete=customlist,HostCompl Ip call s:CopyIp(<q-args>)
cabbr IP Ip

function! s:Trust(...)
  let host = get(a:000, 0, g:HOST)
  if str2nr(host) > 0
    let ip = "10.1.20." .. host
    let host = "root@" .. ip
  else
    let ssh_config = systemlist(["ssh", "-G", host])
    call filter(ssh_config, 'v:val =~ "^hostname"')
    let ip = split(ssh_config[0])[1]
  endif
  let cmds = []
  call add(cmds, "ssh-keygen -R " .. ip)
  call add(cmds, "echo 'Waiting for connection...'")
  call add(cmds, "ssh_wait_silent " .. host)

  botr split
  enew
  let id = termopen(join(cmds, ";"))
  startinsert
  return id
endfunction

command -nargs=+ -complete=customlist,DoCompl Do call s:Do(<f-args>)
"}}}

""""""""""""""""""""""""""""AI distro"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#FetchAI()
  let targets = [
        \ ["~/libalcatraz", "master", "libalcatraz_git.bb"],
        \ ["~/obsidian-video", "main", "obsidian-video_git.bb"],
        \ ["~/badge-and-face", "obsidian-master", "badge-and-face-obsidian_git.bb"]]

  echo "Fetching from origin..."

  e ~/aidistro/repo
  call git#CleanOrThrow()

  call git#ExecuteOrThrow(["checkout", "master"], "Failed to checkout aidistro master")
  call git#ExecuteOrThrow(["pull", "origin", "master"], "Failed to pull aidistro")

  for [repo, branch, _] in targets
    " Find new hash
    exe "e " .. repo
    call git#ExecuteOrThrow(["fetch", "origin", branch], "Fetch in " .. repo .. " failed")
  endfor

  echo "Fetching completed!"
  for [repo, branch, bitbake] in targets
    " Find new hash
    exe "e " .. repo
    let new_hash = git#HashOrThrow("origin/" .. branch)
    " Find old hash
    let id = QuickFind("~/aidistro/repo", "-regex", ".*" .. bitbake)
    call jobwait([id])
    if search("SRCREV") == 0
      throw "Failed to find bitbake file"
    endif
    normal 0f"vi"y
    let old_hash = @0
    " Compare and exchange
    if new_hash != old_hash
      exe printf("substitute /%s/%s/", old_hash, new_hash)
      write
    endif
  endfor
  " Display changes
  e ~/aidistro/repo
  G
  exe "normal \<C-w>w"
  quit
endfunction

function! work#CommitAI()
  let targets = [
        \ ["~/libalcatraz", "master", "libalcatraz_git.bb"],
        \ ["~/obsidian-video", "main", "obsidian-video_git.bb"],
        \ ["~/badge-and-face", "obsidian-master", "badge-and-face-obsidian_git.bb"]]

  e ~/aidistro/repo
  let cmd = ["diff", "--name-only", "--cached"]
  let staged = git#ExecuteOrThrow(cmd, "Cannot determine what changed in aidistro.")
  for [repo, branch, bitbake] in reverse(targets)
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
    e ~/aidistro/repo
    if empty(issue)
      let ai_branch = "stef/ai"
    else
      let ai_branch = "stef/" .. issue .. "/ai"
    endif
    let cmd = ["checkout", "-b", ai_branch]
    call git#ExecuteOrThrow(cmd, "Failed to create branch " .. ai_branch)
    let ai_msg = repo[2:] .. ": " .. msg
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
  e ~/aidistro/repo
  call git#ExecuteOrThrow(["push", "origin", "HEAD"], "Failed to push branch to origin")
  call init#ToClipboard("https://gitlab.com/Rainbe/Firmware/aidistro/-/merge_requests")
endfunction

function! work#CleanUpAI()
  e ~/aidistro/repo
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

function! AiCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let items = ["Fetch", "Commit", "Test", "Push", "CleanUp"]
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
  call init#CreateCustomQuickfix('Branches', branches, 'work#OnIssueSelected')
endfunction

function! work#OnIssueSelected()
  let issue = work#BranchIssueNumber(getline('.'))
  if !empty(issue)
    call work#OpenJira(issue)
  else
    echo "Nothing to show!"
  endif
  quit
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

function! s:Disassemble(dyn, exe)
  let funcs = systemlist(printf("nm -g%s --defined-only %s", a:dyn, a:exe))
  call map(funcs, 'split(v:val)')
  call filter(funcs, 'toupper(v:val[1]) == "W" || toupper(v:val[1]) == "T"')
  call map(funcs, 'v:val[2]')

  if empty(funcs)
    echo "No symbols!"
    return
  endif
  let unmangled = systemlist("c++filt", funcs)
  call init#CreateCustomQuickfix('Symbols', unmangled, function('s:SelectSymbol', [a:exe]))
  " Much faster than binding it in above 'function'.
  let b:mangled_names = funcs
endfunction

function! s:SelectSymbol(exe)
  let idx = line('.') - 1
  let mangled = b:mangled_names[idx]
  quit

  let objdump = g:SDK_DIR .. "/sysroots/x86_64-aisdk-linux/usr/bin/aarch64-aisys-linux/aarch64-aisys-linux-objdump"
  let disas = systemlist(printf('%s -S --disassemble=%s %s', objdump, mangled, a:exe))
  let nr = init#CreateCustomBuffer('Disassembly', disas)
  below split
  exe "b " .. nr
  call setbufvar(nr, '&expandtab', v:false)
  call setbufvar(nr, '&smarttab', v:false)
  call setbufvar(nr, '&softtabstop', 0)
  call setbufvar(nr, '&tabstop', 8)
  call setbufvar(nr, '&list', v:false)
endfunction

command! -nargs=1 -bang -complete=customlist,DisassembleCompl Disassemble call s:Disassemble(<bang>0 ? 'D' : '', <q-args>)

function! DisassembleCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let files = []
  call add(files, printf("/home/%s/badge-and-face/%s/bin/badge_and_face", $USER, g:BUILD_TYPE))
  call add(files, printf("/home/%s/badge-and-face-rock/%s/bin/badge_and_face", $USER, g:BUILD_TYPE))
  return filter(files, 'stridx(v:val, a:ArgLead) >= 0')
endfunction

function! s:OnVimEnter()
  " Install commands for the first time
  call s:InstallHostCommands()
  call s:StartMaster()
  " Start RSI on the second workspace
  call RsiEnableOn("2")
endfunction

augroup Work
  autocmd! VimEnter * ++once call s:OnVimEnter()
augroup END
