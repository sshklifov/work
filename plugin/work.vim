" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

""""""""""""""""""""""""""""Commit tag"""""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#BranchIssueNumber()
  let branch = init#BranchName()
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
  let obsidian_repos = ["obsidian-video", "libalcatraz", "mpp", "camera_engine_rkaiq", "badge-and-face"]
  if index(obsidian_repos, repo) < 0
    echo "Unsupported repo: " . repo
    return
  endif

  let common_flags = join([
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.4.0/", s:sdk_dir),
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.4.0/aarch64-aisys-linux", s:sdk_dir),
        \ "-O0 -ggdb -U_FORTIFY_SOURCE"])
  let cxxflags = "export CXXFLAGS=" . string(common_flags)
  let cflags = "export CFLAGS=" . string(common_flags)

  let dir = printf("cd %s", FugitiveWorkTree())
  let env = printf("source %s/environment-setup-armv8a-aisys-linux", s:sdk_dir)

  if repo == 'camera_engine_rkaiq'
    let cmake = printf("cmake -S. -B%s -DCMAKE_BUILD_TYPE=%s", g:BUILD_TYPE, g:BUILD_TYPE)
    let cmake .= printf(" -DIQ_PARSER_V2_EXTRA_CFLAGS='-I%s/sysroots/armv8a-aisys-linux/usr/include/rockchip-uapi;", s:sdk_dir)
    let cmake .= printf("-I%s/sysroots/armv8a-aisys-linux/usr/include'", s:sdk_dir)
    let cmake .= " -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DISP_HW_VERSION='-DISP_HW_V30' -DARCH='aarch64' -DRKAIQ_TARGET_SOC='rk3588'"
  else
    let cmake = printf("cmake -B %s -S . -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_BUILD_TYPE=%s", g:BUILD_TYPE, g:BUILD_TYPE)
  endif
  let build = printf("cmake --build %s -j 10", g:BUILD_TYPE)

  let cmds = [dir, env, cxxflags, cflags, cmake, build]
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
  let timestamp = split(output[0])[0]
  let output = systemlist(["ssh", g:HOST, 'date --date="@' .. timestamp .. '" "+%F %T"'])
  if v:shell_error
    call init#ShowErrors(output)
    return
  endif
  let since = output[0]

  let cmd = printf('journalctl -u %s --since="%s"', service_name, since)
  if !empty(a:bang)
    enew
    call termopen(["ssh", g:HOST, cmd .. " -f"])
  else
    let lines = systemlist(["ssh", g:HOST, cmd])
    let nr = init#CreateCustomBuffer('Journal ' .. service_name, lines)
    exe "b " .. nr
  endif
endfunction

function! JournalCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let files = ["/usr/lib/systemd/system/obsidian-video.service",
        \ "/usr/lib/systemd/system/qrcode-scanner.service",
        \ "/usr/lib/systemd/system/badge-and-face.service"]
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

  const fast_sync = v:true
  if fast_sync
    " Include all directories
    call add(cmd, '--include=*/')
    " Include all executables
    let exes = systemlist(["find", dir, "-type", "f", "-executable", "-printf", "%P\n"])
    for exe in exes
      call add(cmd, '--include=' . exe)
    endfor
    " Exclude rest. XXX: ORDER OF FLAGS MATTERS!
    call add(cmd, '--exclude=*')
  endif

  let bang = get(a:000, 0, "")
  if empty(bang)
    call extend(cmd, ["--info=progress2", dir, remote_dir])
    return jobstart(cmd, #{on_stdout: funcref("OnStdout"), on_exit: funcref("OnExit")})
  else
    bot new
    call extend(cmd, ["--info=all4", dir, remote_dir])
    let id = termopen(cmd, #{on_exit: funcref("OnExit")})
    call cursor("$", 1)
    return id
  endif
endfunction

function! s:Resync()
  let dir = FugitiveFind(g:BUILD_TYPE)
  exe printf("autocmd! User MakeSuccessful ++once call s:RemoteSync('%s')", dir)
  call s:ObsidianMake()
endfunction

command -nargs=0 -bang Capability let g:CAPABILITIES = <bang>1

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

function! work#DebugApp(exe, run)
  let opts = s:PrepareApp(a:exe)
  if a:run
    let opts['br'] = init#GetDebugLoc()
  endif
  let opts['ssh'] = g:HOST
  " Part of main init.vim
  call init#Debug(opts)
endfunction

function! s:AppToClipboard(app)
  let app = printf("/var/tmp/%s/%s", g:BUILD_TYPE, a:app)
  try
    let opts = s:PrepareApp(app)
    if has_key(opts, 'user')
      let cmd = printf("sudo -u %s %s", opts['user'], opts['exe'])
    else
      let cmd = opts['exe']
    endif
    call init#ToClipboard(cmd)
  catch
    echo v:exception
  endtry
endfunction

nnoremap <silent> <leader>re <cmd>call <SID>Resync()<CR>
nnoremap <silent> <leader>rv <cmd>call <SID>AppToClipboard("application/obsidian-video")<CR>
nnoremap <silent> <leader>rf <cmd>call <SID>AppToClipboard("application/focus-tool")<CR>
nnoremap <silent> <leader>rq <cmd>call <SID>AppToClipboard("application/qrcode-scanner")<CR>
nnoremap <silent> <leader>rs <cmd>call <SID>AppToClipboard("application/rtsp-server")<CR>
nnoremap <silent> <leader>rb <cmd>call <SID>AppToClipboard("bin/badge_and_face")<CR>
nnoremap <silent> <leader>sdk <cmd>call <SID>FakeSdk()<CR>

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
  echom "SSH master died!"
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
    let g:DEVICE = "p15"
    let s:sdk_dir = "/opt/aisys/obsidian_" .. g:DEVICE
    return v:true
  elseif stridx(lines[0], "rockx-dm-r10") >= 0
    let g:DEVICE = "r10"
    let s:sdk_dir = "/opt/aisys/obsidian_" .. g:DEVICE
    return v:true
  endif
  return v:false
endfunction

function! s:InstallHostCommands()
  exe printf("command! -nargs=? -complete=customlist,RemoteExeCompl Start call init#TryCall('work#DebugApp', <q-args>, v:false)")
  exe printf("command! -nargs=? -complete=customlist,RemoteExeCompl Run call init#TryCall('work#DebugApp', <q-args>, v:true)")
  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Attach call init#RemoteAttach('%s', <q-args>)", g:HOST)
  exe printf("command! -nargs=0 Ssh call init#SshTerm('%s')", g:HOST)
  exe printf("command! -nargs=? -bang Sshfind call init#RemoteRecentFiles('<bang>', '%s', <q-args>)", g:HOST)
  exe printf("command! -nargs=? -complete=customlist,SshfsCompl Scp call init#Scp('%s', empty(<q-args>) ? '/tmp' : <q-args>)", g:HOST)

  command! -nargs=? -complete=customlist,SshfsCompl Ssfs call s:SshfsOnSteroids(<q-args>)
  cabbr SSfs Ssfs
endfunction

function! s:ChangeHost(host)
  if empty(a:host)
    let host = "max_p15"
  else
    let host = a:host
  endif
  call system(["ssh", "-o", "ConnectTimeout=1", host, "exit"])
  if v:shell_error != 0
    echo "Failed to connect to host " . host
  else
    let g:HOST = host
    call s:InstallHostCommands()
    if !s:StartMaster()
      echo "Failed to start SSH master!"
    endif
    if !s:DetermineSdk()
      echo "Failed to determine SDK! You must manually set g:DEVICE"
    endif
  endif
endfunction

function! ChangeHostCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let lines = readfile("/home/" .. $USER .. "/.ssh/config")
  let matches = matchstrlist(lines, 'Host \(\i\+\)$', #{submatches: v:true})
  let hosts = map(matches, "v:val.submatches[0]")
  return filter(hosts, "stridx(v:val, a:ArgLead) >= 0")
endfunction

command! -nargs=? -complete=customlist,ChangeHostCompl Host call s:ChangeHost(<q-args>)
"}}}

""""""""""""""""""""""""""""Utility functions"""""""""""""""""""""""""""" {{{
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
  let cmds = ["StopServices", "DropClients", "UpdateDocker",
        \ "BuildSdk", "BuildImage", "InstallSdk", "InstallImage",
        \ "RefreshImage", "RefreshSdk", "Refresh",
        \ "FakeSdk", "FakeMpp", "FakeImage", "ReverseImage",
        \ "FactoryReset", "Trust", "HostDebugSyms", "PlotTrace",
        \ "BarfPlotTrace", "MemoryMonitor"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function! s:StopServices()
  let stop_list = [
        \ "rtsp-server-noauth",
        \ "rtsp-server.socket",
        \ "rtsp-server.service",
        \ "obsidian-video",
        \ "badge-and-face",
        \ "qrcode-scanner"
        \ ]
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

function! s:RunDocker(cmd)
  sp
  enew
  lcd ~/aidistro
  let cmds = ["sudo", "docker-compose", "run", "--rm", "ubuntu22"]

  let bash_cmd = ["export USE_S3_BUCKET=1",
        \ printf("export MACHINE=rockx-dm-%s", g:DEVICE),
        \ "source /home/stef/aidistro/setup-environment /home/stef/cache"]
  call add(bash_cmd, a:cmd)
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
  call add(cmds, "rm -rf " .. s:sdk_dir .. "/*")
  call add(cmds, printf("%s -d %s -y", most_recent_file, s:sdk_dir))
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:InstallImage()
  let images = systemlist(["find", "/home/" .. $USER .. "/aidistro/cache/tmp/deploy/images/", "-regex", printf(".*%s.*mender", g:DEVICE)])
  if empty(images)
    echo "No image found"
    return
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
  let cb = expand("<SID>") .. "InstallImage"
  call init#OnJobFinished(id, cb)
endfunction

function! s:RefreshSdk()
  let id = s:BuildSdk()
  let cb = expand("<SID>") .. "InstallSdk"
  call init#OnJobFinished(id, cb)
endfunction

function! s:Refresh()
  let id = s:RunDocker("bitbake rock-image && bitbake rock-image -c populate_sdk")
  let cb = expand("<SID>") .. "InstallBoth"
  call init#OnJobFinished(id, cb)
endfunction

function! s:InstallBoth()
  call s:InstallImage()
  call s:InstallSdk()
endfunction

function! s:FakeSdk()
  let cmds = []
  let repo_dir = $HOME .. "/libalcatraz"
  let so_pattern = printf("%s/%s/alcatraz/libalcatraz.so*", repo_dir, g:BUILD_TYPE)
  call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/lib", so_pattern, s:sdk_dir))
  " TODO
  " let pc_pattern = printf("%s/%s/libalcatraz.pc", repo_dir, g:BUILD_TYPE)
  " call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/share/pkgconfig", pc_pattern, s:sdk_dir))
  call add(cmds, printf("rsync -rtv %s/include/alcatraz/ %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz", repo_dir, s:sdk_dir))
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
  call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/lib", so_pattern, s:sdk_dir))
  call add(cmds, printf("rsync -Ltv %s %s:/usr/lib", so_pattern, g:HOST))

  split
  enew
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:HostDebugSyms(pat)
  let dir = s:sdk_dir .. "/sysroots/armv8a-aisys-linux/usr/lib/.debug"
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
  Ssfs /tmp/memory_trace.txt
  e!
  %!c++filt
  setlocal nomodified
  setlocal foldexpr=len(matchstr(getline(v:lnum),'^-*'))
  setlocal foldmethod=expr
  setlocal foldenable
endfunction

function! s:FakeImage()
  let targets = [
        \ ["~/libalcatraz", "master", "libalcatraz_git.bb"],
        \ ["~/obsidian-video", "main", "obsidian-video_git.bb"],
        \ ["~/badge-and-face", "obsidian-master", "badge-and-face-obsidian_git.bb"]]

  for [repo, branch, bitbake] in targets
    " Find new hash
    exe "e " .. repo
    call init#WorkTreeCleanOrThrow()

    " Check if unpushed
    let new_branch = init#BranchName()
    if empty(new_branch)
      throw "Repo " .. repo .. " does not have a branch!"
    endif
    let new_hash = init#HashOrThrow(new_branch)
    if new_hash != init#HashOrThrow("origin/" .. new_branch)
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
  " Run docker in split
  call s:BuildImage()
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
    let dict = FugitiveExecute(['checkout', hash])
    if dict['exit_status'] != 0
      call init#ShowErrors(dict['stdout'])
      throw "Failed to checkout in " .. repo
    endif
    exe "G log"
  endfor
endfunction

function! s:FactoryReset()
  botr split
  enew
  call termopen("ssh " .. g:HOST .. " touch /run/factory-reset/initiate-reset")
endfunction

function! s:Trust(...)
  let host = get(a:, 1, g:HOST)
  let ssh_config = systemlist(["ssh", "-G", host])
  call filter(ssh_config, 'v:val =~ "^hostname"')
  let ip = split(ssh_config[0])[1]
  let cmds = []
  call add(cmds, "ssh-keygen -R " .. ip)
  call add(cmds, "ssh_wait_silent " .. host)
  call add(cmds, "ssh " .. host .. " exit")

  botr split
  enew
  call termopen(join(cmds, ";"))
  startinsert
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
  call init#WorkTreeCleanOrThrow()

  let dict = FugitiveExecute(["checkout", "master"])
  let dict = FugitiveExecute(["pull", "origin", "master"])
  if dict['exit_status'] != 0
    throw "Failed to pull aidistro"
  endif

  for [repo, branch, _] in targets
    " Find new hash
    exe "e " .. repo
    let dict = FugitiveExecute(["fetch", "origin", branch])
    if dict['exit_status'] != 0
      throw "Fetch in " .. repo .. " failed"
    endif
  endfor

  echo "Fetching completed!"
  for [repo, branch, bitbake] in targets
    " Find new hash
    exe "e " .. repo
    let new_hash = init#HashOrThrow("origin/" .. branch)
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
  let dict = FugitiveExecute(["diff", "--name-only", "--cached"])
  if dict['exit_status'] != 0 || dict['stdout'][0] == ''
    throw "Cannot determine what changed in aidistro."
  endif
  let staged = dict['stdout']
  for [repo, branch, bitbake] in reverse(targets)
    let staged_bitbake = filter(copy(staged), 'stridx(v:val, bitbake) >= 0')
    if empty(staged_bitbake)
      continue
    endif
    " Get commit message. This is needed to create the branch and the commit
    exe "e " .. repo
    let dict = FugitiveExecute(["log", "-1", "--format=%B", "origin/" .. branch])
    if dict['exit_status'] != 0
      throw "Cannot determine commit message for " .. repo
    endif
    let msg = dict['stdout'][0]
    let issue = matchstr(msg, 'SW-[0-9]\{4\}')
    " Create branch
    e ~/aidistro/repo
    if empty(issue)
      let ai_branch = "stef/ai"
    else
      let ai_branch = "stef/" .. issue .. "/ai"
    endif
    let dict = FugitiveExecute(["checkout", "-b", ai_branch])
    if dict['exit_status'] != 0
      throw "Failed to create branch " .. ai_branch
    endif
    let ai_msg = repo[2:] .. ": " .. msg
    let dict = FugitiveExecute(["commit", "-m", ai_msg])
    if dict['exit_status'] != 0
      throw printf("Failed to commit changes with message '%s'", ai_msg)
    endif
    " Success
    exe "Gdrop " .. ai_branch
    return
  endfor
  throw "Unexpected failure, fixme!"
endfunction

function! work#PushAI()
  e ~/aidistro/repo
  let dict = FugitiveExecute(["push", "origin", "HEAD"])
  if dict['exit_status'] != 0
    throw "Failed to push branch to origin"
  endif
  call init#ToClipboard("https://gitlab.com/Rainbe/Firmware/aidistro/-/merge_requests")
endfunction

function! work#CleanUpAI()
  e ~/aidistro/repo
  let branch = init#CheckedBranchOrThrow()
  let dict = FugitiveExecute(["checkout", "master"])
  if dict['exit_status'] != 0
    throw "Failed to checkout master"
  endif
  " Not the end of the world if this fails.
  call FugitiveExecute(["reset", "--hard"])
  let dict = FugitiveExecute(["pull", "origin", "master"])
  if dict['exit_status'] != 0
    throw "Failed to pull new changes"
  endif
  let dict = FugitiveExecute(["branch", "-D", branch])
  if dict['exit_status'] != 0
    throw "Failed to delete newly created branch"
  endif
  let issue = matchstr(branch, 'SW-[0-9]\{4\}')
  if !empty(issue)
    call work#OpenJira(issue)
  endif
endfunction

function! AiCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let items = ["Fetch", "Commit", "Push", "CleanUp"]
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
  let keys_sorted = reverse(sort(keys(g:ISSUES), 's:CompareIssues'))
  let lines = map(copy(keys_sorted), 'v:val .. ": " .. g:ISSUES[v:val]["branches"][0][1]')
  let nr = init#CreateCustomQuickfix('Issues', lines, 'work#OnIssueSelected')
  let ns = nvim_create_namespace('')
endfunction

function! s:MyDashboard()
  call init#ToClipboard("https://alcatrazai.atlassian.net/jira/your-work")
endfunction

function! s:CompareIssues(k1, k2)
  return g:ISSUES[a:k1]['timestamp'] - g:ISSUES[a:k2]['timestamp']
endfunction

function! work#OnIssueSelected()
  let issue = getline('.')
  call work#OpenJira(issue)
  quit
endfunction

function! s:OpenCurrent()
  let issue = work#BranchIssueNumber()
  if empty(issue)
    echo "Nothing to show!"
  else
    call work#OpenJira(issue)
  endif
endfunction

function! s:SwitchTo(issue)
  if !has_key(g:ISSUES, a:issue)
    throw "Invalid issue!"
  endif
  let branches = g:ISSUES[a:issue]['branches']
  for [repo, branch] in branches
    let opts = #{prompt: "Check out " .. branch .. " inside " .. repo .. "? ", cancelreturn: "n"}
    let user_resp = input(opts)
    if user_resp[0] !=? 'n'
      exe "sp " .. repo
      call init#SwitchToBranchOrThrow(branch)
      quit
    endif
  endfor
endfunction

function! s:NewBranch(issue, name)
  let repo = FugitiveWorkTree()
  if empty(repo)
    echo "Not inside repository!"
    return
  endif
  let branch = printf("stef/%s/%s", a:issue, a:name)
  let dict = FugitiveExecute(["checkout", "-b", branch])
  if dict['exit_status'] != 0
    call init#ShowErrors(dict['stderr'])
    throw "Failed to create branch"
  endif
  call work#OpenJira(a:issue)
  echom "Did you set issue in progress? "
  let branches = get(g:ISSUES, a:issue, [])
  call add(branches, [repo, branch])
  let opts = #{branches: branches, timestamp: localtime()}
  let g:ISSUES[a:issue] = opts
endfunction

function! s:CopyBranch()
  call init#ToClipboard(init#BranchName())
endfunction

function! s:CopyHash()
  let dict = FugitiveExecute(['rev-parse', 'HEAD'])
  if dict['exit_status'] != 0
    throw "Failed to parse " .. a:commitish
  endif
  let hash = dict['stdout'][0]
  call init#ToClipboard(hash)
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
    exe "G log -S " .. args
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
  let cmds = ["ShowActivity", "MyDashboard", "OpenCurrent", "SwitchTo",
        \ "NewBranch", "CopyBranch", "CopyHash",
        \ "MessageSearch", "CodeSearch", "AuthorSearch"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

command -nargs=+ -complete=customlist,IssueCompl Issue call s:Do(<f-args>)
" }}}

function! s:OnVimEnter()
  " Install commands for the first time
  call s:InstallHostCommands()
  call s:StartMaster()
  let s:sdk_dir = "/opt/aisys/obsidian_" .. g:DEVICE
  " Quick way to map sdk source files to GDB
  command! -nargs=0 Map call PromptDebugSendCommand('map ' .. s:sdk_dir)
  " Start RSI on the second workspace
  call RsiEnable("2")
endfunction

" Used in a keymap for :q and :qa
function ConfirmQuit()
  if exists('s:master_job_id')
    " let args = #{prompt: "Killing SSH master! Are you sure? ", cancelreturn: 'n'}
    " return input(args)[0] !=? 'n'
    echo "Killing SSH master!"
    sleep 200m
    return v:true
  endif
  return v:true
endfunction

augroup Work
  autocmd! VimEnter * ++once call s:OnVimEnter()
augroup END
