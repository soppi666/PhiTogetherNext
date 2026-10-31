@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >/dev/null 2>&1
cd /d D:\code\Godot\Lean\phi-together-next\gdextension
scons -j6 platform=windows target=template_release api_version=4.7 bin/chart_ext.windows.template_release.x86_64.dll
