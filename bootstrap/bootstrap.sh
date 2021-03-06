#!/usr/bin/env bash

# Stop script on NZEC
set -e
# Stop script if unbound variable found (use ${var:-} if intentional)
set -u
# By default cmd1 | cmd2 returns exit code of cmd2 regardless of cmd1 success
# This is causing it to fail
set -o pipefail

# Use in the the functions: eval $invocation
invocation='say_verbose "Calling: ${FUNCNAME[0]}"'

# standard output may be used as a return value in the functions
# we need a way to write text on the screen in the functions so that
# it won't interfere with the return value.
# Exposing stream 3 as a pipe to standard output of the script itself
exec 3>&1

say_err() {
    printf "%b\n" "bootstrap: Error: $1" >&2
}

say() {
    # using stream 3 (defined in the beginning) to not interfere with stdout of functions
    # which may be used as return value
    printf "%b\n" "bootstrap: $1" >&3
}

say_verbose() {
    if [ "$verbose" = true ]; then
        say "$1"
    fi
}

machine_has() {
    eval $invocation
    
    hash "$1" > /dev/null 2>&1
    return $?
}

check_min_reqs() {
    if ! machine_has "curl"; then
        say_err "curl is required to download dotnet. Install curl to proceed."
        return 1
    fi
    
    return 0
}

# args:
# remote_path - $1
# [out_path] - $2 - stdout if not provided
download() {
    eval $invocation
    
    local remote_path=$1
    local out_path=${2:-}

    local failed=false
    if [ -z "$out_path" ]; then
        curl --retry 10 -sSL --create-dirs $remote_path || failed=true
    else
        curl --retry 10 -sSL --create-dirs -o $out_path $remote_path || failed=true
    fi
    
    if [ "$failed" = true ]; then
        say_err "Download failed"
        return 1
    fi
}

verbose=false
repoRoot=`pwd`
toolsLocalPath="<auto>"
cliInstallPath="<auto>"
symlinkPath="<auto>"
sharedFxVersion="<auto>"
force=false
forcedCliLocalPath="<none>"

while [ $# -ne 0 ]
do
    name=$1
    case $name in
        -r|--repositoryRoot|-[Rr]epositoryRoot)
            shift
            repoRoot="$1"
            ;;
        -t|--toolsLocalPath|-[Tt]oolsLocalPath)
            shift
            toolsLocalPath="$1"
            ;;
        -c|--cliInstallPath|-[Cc]liLocalPath)
            shift
            cliInstallPath="$1"
            ;;
        -u|--useLocalCli|-[Uu]seLocalCli)
            shift
            forcedCliLocalPath="$1"
            ;;
        --sharedFrameworkSymlinkPath|--symlink|-[Ss]haredFrameworkSymlinkPath)
            shift
            symlinkPath="$1"
            ;;
        --sharedFrameworkVersion|-[Ss]haredFrameworkVersion)
            sharedFxVersion="$1"
            ;;
        --force|-[Ff]orce)
            force=true
            ;;
        -v|--verbose|-[Vv]erbose)
            verbose=true
            ;;
        *)
            say_err "Unknown argument \`$name\`"
            exit 1
            ;;
    esac

    shift
done

if [ $toolsLocalPath = "<auto>" ]; then
    toolsLocalPath="$repoRoot/Tools"
fi

if [ $cliInstallPath = "<auto>" ]; then
    if [ $forcedCliLocalPath = "<none>" ]; then
        cliInstallPath="$toolsLocalPath/dotnetcli"
    else
        cliInstallPath=$forcedCliLocalPath
    fi
fi

if [ $symlinkPath = "<auto>" ]; then
    symlinkPath="$toolsLocalPath/dotnetcli/shared/Microsoft.NETCore.App/version"
fi

rootToolVersions="$repoRoot/.toolversions"
bootstrapComplete="$toolsLocalPath/bootstrap.complete"

# if the force switch is specified delete the semaphore file if it exists
if [[ $force && -f $bootstrapComplete ]]; then
    rm -f $bootstrapComplete
fi

# if the semaphore file exists and is identical to the specified version then exit
if [[ -f $bootstrapComplete && `cmp $bootstrapComplete $rootToolVersions` ]]; then
    say "$bootstrapComplete appears to show that bootstrapping is complete.  Use --force if you want to re-bootstrap."
    exit 0
fi

initCliScript="dotnet-install.sh"
dotnetInstallPath="$toolsLocalPath/$initCliScript"

# blow away the tools directory so we can start from a known state
if [ -d $toolsLocalPath ]; then
    # if the bootstrap.sh script was downloaded to the tools directory don't delete it
    find $toolsLocalPath -type f -not -name boostrap.sh -exec rm -f {} \;
else
    mkdir $toolsLocalPath
fi

if [ $forcedCliLocalPath = "<none>" ]; then
    check_min_reqs

    # download CLI boot-strapper script
    download "https://raw.githubusercontent.com/dotnet/cli/rel/1.0.0/scripts/obtain/dotnet-install.sh" "$dotnetInstallPath"
    chmod u+x "$dotnetInstallPath"

    # load the version of the CLI
    rootCliVersion="$repoRoot/.cliversion"
    dotNetCliVersion=`cat $rootCliVersion`

    # now execute the script
    say_verbose "installing CLI: $dotnetInstallPath --version $dotNetCliVersion --install-dir $cliInstallPath"
    $dotnetInstallPath --version "$dotNetCliVersion" --install-dir $cliInstallPath
    if [ $? != 0 ]; then
        say_err "The .NET CLI installation failed with exit code $?"
        exit $?
    fi
fi

if [ $sharedFxVersion = "<auto>" ]; then
    runtimesPath="$cliInstallPath/shared/Microsoft.NETCore.App"
    sharedFxVersion=`ls $runtimesPath | sort --version-sort -r | head -n 1`
fi

# create a junction to the shared FX version directory. this is
# so we have a stable path to dotnet.exe regardless of version.
junctionTarget="$runtimesPath/$sharedFxVersion"
junctionParent="$(dirname "$junctionTarget")"

if [ ! -d $junctionParent ]; then
    mkdir -p $junctionParent
fi

ln -s $symlinkPath $junctionTarget

# create a project.json for the packages to restore
projectJson="$toolsLocalPath/project.json"
pjContent="{ \"dependencies\": {"
while read v; do
    IFS='=' read -r -a line <<< "$v"
    pjContent="$pjContent \"${line[0]}\": \"${line[1]}\","
done <$rootToolVersions
pjContent="$pjContent }, \"frameworks\": { \"netcoreapp1.0\": { } } }"
echo $pjContent > $projectJson

# now restore the packages
buildToolsSource="${BUILDTOOLS_SOURCE:-https://dotnet.myget.org/F/dotnet-buildtools/api/v3/index.json}"
nugetOrgSource="https://api.nuget.org/v3/index.json"

packagesPath="$repoRoot/packages"
dotNetExe="$cliInstallPath/dotnet"
restoreArgs="restore $projectJson --packages $packagesPath --source $buildToolsSource --source $nugetOrgSource"
say_verbose "Running $dotNetExe $restoreArgs"
$dotNetExe $restoreArgs
if [ $? != 0 ]; then
    say_err "project.json restore failed with exit code $?"
    exit $?
fi

# now stage the contents to tools directory and run any init scripts
while read v; do
    IFS='=' read -r -a line <<< "$v"
    # verify that the version we expect is what was restored
    pkgVerPath="$packagesPath/${line[0]}/${line[1]}"
    if [ ! -d $pkgVerPath ]; then
        say_err "Directory $pkgVerPath doesn't exist, ensure that the version restore matches the version specified."
        exit 1
    fi
    # at present we have the following conventions when staging package content:
    #   1.  if a package contains a "tools" directory then recursively copy its contents
    #       to a directory named the package ID that's under $ToolsLocalPath.
    #   2.  if a package contains a "libs" directory then recursively copy its contents
    #       under the $ToolsLocalPath directory.
    #   3.  if a package contains a file "lib\init-tools.cmd" execute it.
    if [ -d "$pkgVerPath/tools" ]; then
        destination="$toolsLocalPath/${line[0]}"
        mkdir -p $destination
        cp -r $pkgVerPath/* $destination
    fi
    if [ -d "$pkgVerPath/lib" ]; then
        cp -r $pkgVerPath/lib/* $toolsLocalPath
    fi
    if [ -f "$pkgVerPath/lib/init-tools.sh" ]; then
        "$pkgVerPath/lib/init-tools.sh" "$repoRoot" "$dotNetExe" "$toolsLocalPath" > "init-${line[0]}.log"
    fi
done <$rootToolVersions

cp $rootToolVersions $bootstrapComplete

say "Bootstrap finished successfully."

