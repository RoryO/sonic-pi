# Assumptions: 
# Visual Studio and c++ cli tools installed
# QT installed. This is true on appveyor.

function main {
    $script:spi_home = Join-Path -Path $PSCommandPath -ChildPath "..\..\..\..\" -Resolve
    $script:ruby_home = $script:spi_home + "app\server\ruby"

    if (-Not $env:QTDIR) {
        $env:QTDIR = (Get-ChildItem "C:\Qt" | Sort-Object Name)[0].FullName
    }

    if(-Not $env:BOOST_ROOT) {
        $boost_dir = (Get-ChildItem "C:\boost*" | Sort-Object Name)
        if($boost_dir) { $env:BOOST_ROOT = $boost_dir[0].FullName}
    }

    $script:qt_bin = "$env:QTDIR\msvc2017_64\bin"
    $env:QMAKEFEATURES = "$env:QMAKEFEATURES;$script:qwt_dir"

    # while using the system tmp folder is nicer and allows for the OS to GC leftovers,
    # msbuild yells at us later when running any builds within the tmp folder
    # also deliberately leaving off drive letter since we may not know where we are originally
    $script:tmp_dir = New-Item -ItemType Directory "\build_tmp\$([System.Guid]::NewGuid())"
    Set-Location $script:tmp_dir

    try {
        Install-Choco
        Install-Git
        Install-Ruby
        Install-Boost
        Install-cmake
        Install-qwt
        Install-QScintilla
        Install-Sndfile
        Install-Supercollider
        Install-Aubio
        Install-SPI
    }
    finally {
        Set-Location $HOME
        Remove-Item -Recurse -Force $script:tmp_dir
    }
}

function Install-Ruby {
    if ((Get-Command ruby.exe -ErrorAction SilentlyContinue) -And ($(ruby.exe -e "puts Integer(RUBY_VERSION.split('.').fetch(1)) >= 3") -eq "true")) {
        $src_ruby_dir = Join-Path -Path (Split-Path -Path (Get-Command ruby.exe).Path) -ChildPath ".." -Resolve
    }
    else {
        Write-Output "Installing Ruby 2.6"
        Write-Output "===`n"
        $src_ruby_dir = "C:\tools\ruby26"
        Start-Process choco -Wait -NoNewWindow -ArgumentList "install ruby", "--yes", "--version=2.6.5.1"
    }

    # If you do not do this msys2 build utils are placed ahead of the msvc utils in $env:PATH which causes cryptic
    # nmake errors later
    # apparently disabling ridk _also_ removes the msvc path vars. yaaaaaaay
    $original_path = $env:PATH
    New-Item -Type Directory -Path $script:ruby_home -ErrorAction SilentlyContinue
    Copy-Item -Recurse "$src_ruby_dir\*" -Force $script:ruby_home

    # This is safely repeatable if there's an already existing msys2 installation as described by https://chocolatey.org/packages/msys2
    Start-Process "choco" -Wait -NoNewWindow -ArgumentList "install msys2", "--yes", "--params /NoUpdate"
    refreshenv
    & "$script:ruby_home\ridk_use\ridk.ps1" install 2 3
    & "$script:ruby_home\ridk_use\ridk.ps1" enable
 
    # Write-Output "Installing Ruby gems"
    # Write-Output "===`n"
    # $gems = "win32-process windows-pr fast_osc ffi hamster wavefile rubame aubio kramdown multi_json ruby-beautify memoist"
    # Start-Process "$script:ruby_home\bin\gem.cmd" -NoNewWindow -Wait -ArgumentList "install $gems --no-document" 
    
    # these two are necessary until (https://github.com/libgit2/rugged/pull/825/files) is released
    # & "$script:ruby_home\ridk_use\ridk.ps1" exec pacman -S --noconfirm mingw-w64-x86_64-libssh2 mingw-w64-x86_64-cmake 
    # Start-Process "$script:ruby_home\bin\gem.cmd" -NoNewWindow -Wait -ArgumentList "install rugged", "--version=0.27 --no-document"
    Set-Location $script:ruby_home
    Start-Process git -Wait -NoNewWindow -ArgumentList "clone https://github.com/RoryO/rugged"
    Set-Location "$script:ruby_home\rugged"
    Start-Process git -Wait -NoNewWindow -ArgumentList "submodule update --init --recursive"
    Write-Output "$script:ruby_home\bin\gem"
    Start-Process "$script:ruby_home\bin\gem.cmd" -Wait -NoNewWindow -ArgumentList "build rugged.gemspec"
    Start-Process "$script:ruby_home\bin\gem.cmd" -Wait -NoNewWindow -ArgumentList "install *.gem"
    $env:PATH = $original_path
}

function Install-cmake {
    if (Get-Command cmake.exe -ErrorAction SilentlyContinue) { return }
    Write-Output "Installing CMake"
    Write-Output "===`n"
    Start-Process choco -NoNewWindow -Wait -ArgumentList "install cmake", "--yes", "--installargs", "ADD_CMAKE_TO_PATH=User"
    refreshenv
}
function Install-qwt {
    Write-Output "Installing qwt"
    Write-Output "===`n"
    # mad props to sourceforge for deliberately breaking automation for ~~~engagement~~~
    # the download link appears unstable, something server side detects if you've viewed the interstitial pages. lovely.
    # tested by using the same url on one system to another. origial system viewed the page in a browser, works file in cli
    # other system never visited the url, gets an intersitital page instead of the zip file even when generating a recent timestamp
    # $current_time = Get-Date -UFormat "%s"
    # $download_url = "https://downloads.sourceforge.net/project/qwt/qwt/6.1.4/qwt-6.1.4.zip?r=https%3A%2F%2Fsourceforge.net%2Fprojects%2Fqwt%2Ffiles%2Fqwt%2F6.1.4%2Fqwt-6.1.4.zip%2Fdownload&ts=$current_time"

    # so, lets hope this github mirror does not disappear
    $version_string = "6.1.4"
    $download_url = "https://github.com/opencor/qwt/archive/v$version_string.zip"
    Invoke-WebRequest -Uri $download_url -OutFile "qwt.zip"
    $script:qwt_dir = "$script:tmp_dir\qwt-$version_string"
    Expand-Archive "qwt.zip" -DestinationPath $script:tmp_dir -Force

    Set-Location $script:qwt_dir
    Start-Process "$script:qt_bin\qmake.exe" -Wait -NoNewWindow -ArgumentList "qwt.pro"
    Start-Process "nmake.exe" -Wait -NoNewWindow

    # about 30% of the time the second nmake command starts and hangs. i dunno why. 
    # inspecting the nmake process yields no information. computers, yay! 
    $completed = $null
    Start-Sleep -seconds 10
    while (-Not $completed) {
        Write-Host "`n`n`nstarting nmake process`n`n`n"
        $timed_out = $null
        $p = Start-Process "nmake.exe" -NoNewWindow -ArgumentList "install" -PassThru
        $p | Wait-Process -Timeout 15 -ErrorVariable $timed_out
        if ($timed_out) {
            Stop-Process $p
        }
        else {
            $completed = 1
        }
    }
}

function Install-QScintilla {
    Write-Output "Installing QScintilla"
    Write-Output "===`n"

    $version_string = "2.11.3"
    $download_url = "https://www.riverbankcomputing.com/static/Downloads/QScintilla/$version_string/QScintilla-$version_string.zip"
    Invoke-WebRequest -Uri $download_url -OutFile "qscintilla.zip"
    $script:qsc_dir = "$script:tmp_dir\qscintilla-$version_string"
    Expand-Archive "qscintilla.zip" -DestinationPath $script:tmp_dir -Force

    Set-Location "$script:qsc_dir\qt4qt5"
    Start-Process "$script:qt_bin\qmake.exe" -Wait -NoNewWindow -ArgumentList "qscintilla.pro"
    Start-Process "nmake.exe" -Wait -NoNewWindow
    Start-Process "nmake.exe" -Wait -NoNewWindow -ArgumentList "install"
}

function Install-Aubio {
    Write-Output "Installing Aubio"
    Write-Output "===`n"

    Set-Location $script:tmp_dir
    $version_string = "0.4.6"
    $download_url = "https://aubio.org/bin/0.4.6/aubio-$version_string-win64.zip"

    Invoke-WebRequest -Uri $download_url -OutFile "aubio.zip"
    Expand-Archive "aubio.zip" -DestinationPath $script:tmp_dir
    Copy-Item "$script:tmp_dir\aubio-$version_string-win64\bin\libaubio-5.dll" -Destination "$script:ruby_home\bin\aubio1.dll"
}

function Install-Boost {
    if ($env:BOOST_ROOT) { return }
    Write-Output "Installing Boost"
    Write-Output "===`n"

    Set-Location $script:tmp_dir
    $boost_version_string = "1_72_0"
    $download_url = "https://dl.bintray.com/boostorg/release/1.72.0/source/boost_$boost_version_string.zip"
    Invoke-WebRequest -Uri $download_url -OutFile "boost.zip"
    New-Item -ItemType Directory -Path "C:\boost"
    Expand-Archive "boost.zip" -DestinationPath "C:\"
    Set-Location "C:\boost_$boost_version_string"

    Start-Process -Wait -NoNewWindow ".\bootstrap.bat"
    Start-Process -Wait -NoNewWindow ".\b2"
}

function Install-Choco {
    if (-Not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Output "Installing Chocolatey"
        Write-Output "===`n"
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

        $env:ChocolateyInstall = Convert-Path "$((Get-Command choco).Path)\..\.."   
    }

    # sometimes if we are in powershell as a subshell of cmd we get all kinds of screwed up
    # this ensures choco is right for powershell
    Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
}

function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) { return }
    Start-Process choco -Wait -NoNewWindow -ArgumentList "install git", "--yes"
    refreshenv
}

function Install-Sndfile {
    Write-Output "Installing sndfile"
    Write-Output "===`n"

    Set-Location $script:tmp_dir
    $download_url = "http://www.mega-nerd.com/libsndfile/files/libsndfile-1.0.28-w64-setup.exe"
    Invoke-WebRequest -Uri $download_url -OutFile "sndfile.exe"
    Start-Process ".\sndfile.exe" -NoNewWindow -ArgumentList "/verysilent"
    # this is irritating. there's a timed nagware screen circa windows 3.1 which pops up even with a silent installation
    # it's a child process which spawns after installation completes, and blocks the completion of the
    # parent installation process
    # this is why we cannot -Wait the previous process
    # so, wait for a bit of time and then kill it.
    Start-Sleep -Seconds 10
    $p = Get-Process -Name "sndfile-about"
    Stop-Process $p
}

# while it makes more sense calling these functions 'Build-Supercollider'
# the verb Build doesn't appear in powershell until v6
function Install-Supercollider {
    Write-Output "Building Supercollider"
    Write-Output "===`n"

    Set-Location $script:tmp_dir
    Start-Process git -Wait -NoNewWindow -ArgumentList "clone https://github.com/supercollider/supercollider.git"

    $asio_download_url = "https://www.steinberg.net/asiosdk"
    Invoke-WebRequest -Uri $asio_download_url -OutFile "asio.zip"
    # more irritations. there's a subfolder inside the asio sdk that we cannot predict the name of.
    $asio_extraction_path = New-Item -ItemType Directory -Path "$script:tmp_dir\asio"
    Expand-Archive -Path "asio.zip" -DestinationPath $asio_extraction_path
    $asio_path = (Get-ChildItem $asio_extraction_path)[0].FullName
    $asio_dest = New-Item -ItemType Directory -Path "$script:tmp_dir\supercollider\external_libraries\asiosdk"
    Copy-Item -Recurse -Path "$asio_path\*" -Destination $asio_dest

    Set-Location "$script:tmp_dir\supercollider"
    Start-Process git -Wait -NoNewWindow -ArgumentList "submodule update --init --recursive"
    New-Item -ItemType Directory -Name "build"
    Set-Location build

    # this fails if the qt installation does not have the qtwebengine component installed
    # run the qt maintenance tool and install the qtwebengine component
    Start-Process cmake -Wait -NoNewWindow -ArgumentList '-G "Visual Studio 16 2019"', "-DCMAKE_PREFIX_PATH=`"$env:QTDIR\msvc2017_64`"", ".."
    Start-Process cmake -Wait -NoNewWindow -ArgumentList "--build .", "--config Release"
    Copy-Item -Recurse -Path "$script:tmp_dir\supercollider\build\server\scsynth\Release\*" -Destination "$script:spi_home\app\server\native\windows"
}

function Install-SPI {
    Copy-Item -Recurse -Force -Path "$script:tmp_dir\supercollider\build\server\scsynth\Release\*" -Destination "$script:spi_home\app\server\native\windows"

    Set-Location "$script:ruby_home\bin"
    Start-Process ".\ruby.exe" -Wait -NoNewWindow -ArgumentList "i18n-tool.rb -t"
    Copy-Item "$script:spi_home\app\gui\qt\utils\ruby_help.tmpl" "$script:spi_home\app\gui\qt\utils\ruby_help.h"
    Start-Process ".\ruby.exe" -Wait -NoNewWindow -ArgumentList "qt-doc.rb -o utils\ruby_help.h"
    
    Set-Location "$script:spi_home\app\gui\qt"
    Start-Process "$script:qt_bin\lrelease" -Wait -NoNewWindow -ArgumentList "SonicPi.pro"
    Start-Process "$script:qt_bin\qmake" -Wait -NoNewWindow -ArgumentList "SonicPi.pro"
    Start-Process nmake -Wait -NoNewWindow
    Set-Location release
    Start-Process "$script:qt_bin\windeployqt" -Wait -NoNewWindow -ArgumentList "sonic-pi.exe", "-printsupport"
    
    Copy-Item "$script:qwt_dir\lib\qwt.dll" "$script:spi_home\app\gui\qt\release"
    Copy-Item "$script:qsc_dir\Qt4Qt5\release\qscintilla2_qt5.dll" "$script:spi_home\app\gui\qt\release"
    Copy-Item "$script:qt_bin\Qt5OpenGL.dll" "$script:spi_home\app\gui\qt\release"
}

main