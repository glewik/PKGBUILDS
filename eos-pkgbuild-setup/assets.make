#!/bin/bash

# TODO:
#   - check if deletion of e.g. pamac-aur might remove also pamac-aur-git (names have same beginning)

echoreturn() { echo "$@" ; }     # for "return" values!

echo2()   { echo   "$@" >&2 ; }    # output to stderr
printf2() { printf "$@" >&2 ; }    # output to stderr
read2()   { read   "$@" >&2 ; }    # output to stderr

DIE()   { echo2 "Error: $1." ; Destructor ; exit 1 ; }
WARN()  { echo2 "Warning: $1." ; }

Pushd() { pushd "$@" >/dev/null || DIE "${FUNCNAME[1]}: pushd $* failed" ; }

Popd()  {
    local count=1 xx
    case "$1" in
        -c=*) count=${1:3} ; shift ;;
        -c*)  count=${1:2} ; shift ;;
    esac
    for ((xx=0;xx<count;xx++)) ; do
        popd  "$@" >/dev/null || DIE "${FUNCNAME[1]}: popd $* failed"
    done
}

Build()
{
    local pkgdirname="$1"
    local assetsdir="$2"
    local pkgbuilddir="$3"
    local pkgname
    local pkg
    local workdir=$(mktemp -d)
    local log=$workdir/buildlog-"$pkgdirname".log
    local missdeps="Missing dependencies:"

    Pushd "$workdir"
      cp -r "$pkgbuilddir" .
      pkgname="$(PkgBuildName "$pkgdirname")"
      Pushd "$pkgdirname"

      # now build, assume we have PKGBUILD
      # special handling for missing dependencies
      LANG=C makepkg --clean 2>/dev/null >"$log" || {
          if [ -z "$(grep "$missdeps" "$log")" ] ; then
              Popd -c2
              DIE "makepkg for '$pkgname' failed"
          fi
          echo2 "Installing $(echo "$missdeps" | tr [:upper:] [:lower:])"
          grep -A100 "$missdeps" "$log" | grep "^  -> " >&2
          :
          makepkg --syncdeps --clean >/dev/null || { Popd -c2 ; DIE "makepkg for '$pkgname' failed" ; }
      }
      pkg="$(ls -1 ${pkgname}-[0-9]*.pkg.tar.$_COMPRESSOR)"
      mv $pkg "$assetsdir"
      pkg="$assetsdir/$pkg"

      Popd
    Popd
    rm -rf "$workdir"
    echoreturn "$pkg"
}

PkgBuildName()
{
    local pkgdirname="$1"
    source "$PKGBUILD_ROOTDIR"/"$(basename "$pkgdirname")"/PKGBUILD
    echoreturn "$pkgname"
}

PkgBuildVersion()
{
    local pkgdirname="$1"
    source "$PKGBUILD_ROOTDIR"/"$(basename "$pkgdirname")"/PKGBUILD
    echoreturn "${pkgver}-$pkgrel"
}

LocalVersion()
{
    local Pkgname="$1"
    local pkgs
    local xx
    
    Pkgname="$(basename "$Pkgname")"

    for xx in zst xz ; do         # order is important because of change to zstd!
        pkgs="$(ls -1 "$ASSETSDIR"/${Pkgname}-[0-9]*.pkg.tar.$xx 2>/dev/null)"    # $_COMPRESSOR
        test -n "$pkgs" && break
    done

    case "$(echo "$pkgs" | wc -l)" in
        0) echoreturn "0" ; return ;;
        1) ;;
        *) WARN "$Pkgname: there is not only one version locally, using the latest."
           pkgs="$(echo "$pkgs" | tail -n 1)"
           ;;
    esac

    local tail="$(echo "$pkgs" | sed 's|^.*/'"$Pkgname"'-||')"
    local ver="$(echo "$tail" | cut -d '-' -f 1)"
    local rel="$(echo "$tail" | cut -d '-' -f 2)"

    echoreturn "${ver}-$rel"
}

JustPkgname()
{
    local fakepath="$1"
    case "$fakepath" in
        ./*)      echoreturn "${fakepath:2}" ;;
        aur/*)    echoreturn "${fakepath:4}" ;;
        *)        echoreturn "${fakepath}"   ;;
    esac
}

HookIndicator() {
    local mark="$1"
    if [ "$fetch" = "yes" ] ; then
        echo2 -n "$mark "
    fi
}

ExplainHookMarks() {
    printf2 "\nNote: mark %s above means a package hook from file %s was executed.\n\n" "$hook_yes" "$ASSETS_CONF"
}

ListNameToPkgName()
{
    # PKGNAMES array (from $ASSETS_CONF) uses certain syntax for package names
    # to mark where they come from, either local or AUR packages.
    # AUR packages are fetched from AUR, local packages
    # are simply used from a local folder.
    #
    # Supported syntax:
    #    pkgname          local package
    #    ./pkgname        local package (emphasis)
    #    aur/pkgname      AUR package

    local xx="$1"
    local fetch="$2"
    local pkgname
    local hook

    pkgname=$(JustPkgname "$xx")

    if [ "${xx::4}" = "aur/" ] ; then
        case "$fetch" in
            yes)
                rm -rf "$pkgname"
                yay -Ga "$pkgname" >/dev/null || DIE "'yay -Ga $pkgname' failed."
                rm -rf "$pkgname"/.git                          # not needed
                ;;
        esac
    fi

    # A pkg may need some changes:
    hook="${ASSET_PACKAGE_HOOKS["$pkgname"]}"
    if [ -n "$hook" ] ; then
        HookIndicator "$hook_yes"
        $hook
    else
        HookIndicator "$hook_no"
    fi

    echoreturn "$pkgname"
}

Assets_clone()
{
    if [ $use_local_assets -eq 1 ] ; then
        return
    fi

    local xx hook

    # echo2 "It is possible that your local release assets in folder $ASSETSDIR"
    # echo2 "are not in sync with github."
    # echo2 "If so, you can delete your local assets and fetch assets from github now."
    # read -p "Delete local assets and fetch them from github now (y/N)? " xx >&2

    case "$REPONAME" in
        endeavouros_calamares) ;;  # many maintainers, so make sure we have the same assets!
        *)
            if [ -n "$(ls -1 *.pkg.tar.{xz,zst} 2> /dev/null)" ] ; then   # $_COMPRESSOR
                printf2 "\n%s " "Fetch assets from github (Y/n)?"
                read2

                case "$REPLY" in
                    [yY]*|"") ;;
                    *)
                        echo2 "Using local assets."
                        echo2 ""
                        return
                        ;;
                esac
            fi
            ;;
    esac

    Pushd "$ASSETSDIR"

    echo2 "Deleting all local assets..."
    # $pkgname in PKGBUILD may not be the same as values in $PKGNAMES,
    # so delete all packages and databases.
    rm -f *.{db,files,sig,old,xz,zst,txt}                                      # $_COMPRESSOR
    local leftovers="$(command ls *.{db,files,sig,old,xz,zst} 2>/dev/null)"    # $_COMPRESSOR
    test -z "$leftovers" || DIE "removing local assets failed!"

    echo2 "Fetching all github assets..."
    hook="${ASSET_PACKAGE_HOOKS["assets_mirrors"]}"
    for xx in "${RELEASE_TAGS[@]}" ; do
        hub release download $xx
        test -n "$hook" && { $hook && break ; }  # we need assets from only one tag since assets in other tags are the same
    done
    sleep 1

    Popd
}

IsEmptyString() {
    local name="$1"
    local value="${!name}"
    test -n "$value" || DIE "value of variable '$name' is empty"
}
DirExists() {
    local name="$1"
    local docreate="$2"
    local value="${!name}"

    case "$docreate" in
        yes) mkdir -p "$value" ;;
        *)   test -d "$value" || {
                 DIE "variable '$name' has folder name value '$value' - the folder does not exist"
             } ;;
    esac
}

ShowPrompt() {
    printf2 "%-35s : " "$1"
}

RationalityTests()
{
    ShowPrompt "Checking values in $ASSETS_CONF"

    IsEmptyString ASSETSDIR
    IsEmptyString PKGBUILD_ROOTDIR
    IsEmptyString GITDIR
    IsEmptyString PKGNAMES
    IsEmptyString REPONAME
    IsEmptyString RELEASE_TAGS
    IsEmptyString SIGNER
    DirExists ASSETSDIR
    DirExists PKGBUILD_ROOTDIR yes  # silently create the dir
    DirExists GITDIR

    echo2 "done."
}

Constructor()
{
    # make sure .git symlink exists
    test -e "$ASSETSDIR"/.git || ln -s "$GITDIR"/.git "$ASSETSDIR"

    test "$GITDIR"/.git -ef "$ASSETSDIR"/.git || \
        DIE "$ASSETS_CONF: error: folder '$ASSETSDIR/.git' differs from '$GITDIR/.git'"

}

Destructor()
{
    #test -L "$ASSETSDIR"/.git && rm -f "$ASSETSDIR"/.git
    test -n "$buildsavedir" && rm -rf "$buildsavedir"
}

ShowOldCompressedPackages() {
    # If we have *both* .zst and .xz package, show the .xz package.

    local pkg pkgdir pkgname
    local pkg2 pkg22

    for pkg in $(ls "$ASSETSDIR"/*.pkg.tar.zst 2>/dev/null) ; do
        pkgname="$(basename "$pkg")"
        pkgdir="$(dirname "$pkg")"
        pkg2="$pkgdir/$(echo "$pkgname" | sed 's|\-[0-9].*$||')"
        pkg22="$(ls "$pkg2"-*.pkg.tar.xz 2>/dev/null)"
        if [ -n "$pkg22" ] ; then
            for pkg2 in $pkg22 ; do
                printf2 "Remove old packages:\n    %s\n    %s\n" "$pkg2" "$pkg2.sig"
                rm -i "$pkg2" "$pkg2.sig"
            done
        fi
    done
}

_pkgbuilds_eos_hook()
{
    # A hook function to make sure local EndeavourOS PKGBUILDS are up to date.

    local dir_above_pkgbuilds="$PKGBUILD_ROOTDIR"/..
    local conf=assets.conf

    pushd "$dir_above_pkgbuilds" >/dev/null || {
        echo2 "Error: $conf: cannot cd to '$dir_above_pkgbuilds'."
        exit 1
    }
    rm -rf "$PKGBUILD_ROOTDIR"
    git clone https://github.com/endeavouros-team/PKGBUILDS.git >& /dev/null || {
        echo2 "Error: $conf: git clone https://github.com/endeavouros-team/PKGBUILDS.git failed."
        Popd
        exit 1
    }
    rm -rf "$PKGBUILD_ROOTDIR"/.git
    touch "$PKGBUILD_ROOTDIR"/NOTE-THIS-IS-A-TEMPORARY-FOLDER
    popd >/dev/null
}

RunPreHooksEOS()
{
    test "$SIGNER" = "EndeavourOS" && _pkgbuilds_eos_hook
}

RunPreHooks()
{
    RunPreHooksEOS
    if [ -n "$ASSET_HOOKS" ] ; then
        ShowPrompt "Running asset hooks"
        local xx
        for xx in "${ASSET_HOOKS[@]}" ; do
            $xx
        done
        echo2 "done."
    fi
}

RunPostHooks()
{
    local newrepodir
    if [ -n "$built" ] || [ "$repoup" = "1" ] ; then
        case "$REPONAME" in
            endeavouros) newrepodir="$ASSETSDIR/../../repo" ;;
            *)           newrepodir="$GITDIR" ;;
        esac
        if [ -r "$newrepodir/GitUpdate" ] ; then
            cd "$newrepodir"
            ./GitUpdate
        fi
    fi
    return
    
    if [ -n "$ASSET_POST_HOOKS" ] ; then
        ShowPrompt "Running asset post hooks"
        local xx
        for xx in "${ASSET_POST_HOOKS[@]}" ; do
            $xx
        done
        echo2 "done."
    fi
}

WantAurDiffs() {
    local xx="$1"
    local diff_url="https://aur.archlinux.org/cgit/aur.git/diff/?h=$pkgdirname&context=1"
#   local diff_url="https://aur.archlinux.org/cgit/aur.git/commit/?h=$pkgdirname&context=1"
#   local browser=/usr/bin/xdg-open   # firefox by default

    case "$xx" in
        aur/*)
            if [ "$aurdiff" = "0" ] && [ "$already_asked_diffs" = "0" ] ; then
                already_asked_diffs=1
                read2 -p "[${ask_timeout}s] AUR updates are available. Want to see diffs (Y/n)? " -t $ask_timeout
                if [ $? -eq 0 ] ; then
                    case "$REPLY" in
                        ""|[yY]*) aurdiff=1 ;;
                    esac
                else
                    echo2 no.   # no diffs if timeout
                fi
            fi
            if [ "$aurdiff" = "1" ] ; then
                case "$xx" in
                    aur/*)
                        AUR_DIFFS+=("$diff_url")
                        #$browser "$diff_url" >& /dev/null
                        ;;
                esac
            fi
            ;;
    esac
}

Browser() {
    local browser
    if [ -x /usr/bin/firefox ] ; then
        browser=/usr/bin/firefox
    elif [ -x /usr/bin/chromium ] ; then
        browser=/usr/bin/chromium
    else
        browser=/usr/bin/xdg-open
    fi
    $browser "$@"
}

Exit()
{
    local code="$1"
    Destructor
    exit "$code"
}

_SleepSeconds() {
    local sec="$1"
    local xx
    for ((xx=sec; xx>0; xx--)) ; do
        printf2 "\r%s   " "$xx"
        sleep 1
    done
    printf2 "\r%s\n" "$xx"
}

MirrorCheck() {
    if [ ! -r endeavouros.db ] ; then
        return
    fi
    local checker="/usr/share/endeavouros/scripts/mirrorcheck"
    local mirror_check="Alpix mirror check"
    local timeout
    local opt="--no-filelist"

    test "$use_filelist" = "yes" && opt=""

    if [ -n "$built" ] ; then
        timeout="$mirror_check_wait"
    else
        timeout=3
    fi
    if [ -x "$checker" ] ; then
        if [ $timeout -eq 180 ] ; then
            read2 -p "Do $mirror_check (Y/n)?"
        fi
        case "$REPLY" in
            ""|[yY]*)
                echo2 "Starting $mirror_check after countdown, please wait..."
                _SleepSeconds $timeout
                $checker $opt .
                ;;
        esac
    else
        echo2 "Sorry, checker $checker not found."
        echo2 "Cannot do $mirror_check."
    fi
}

Usage() {
    cat <<EOF >&2
$PROGNAME: Build packages and transfer results to github.

$PROGNAME [ options ]
Options:
    -n  | -nl | --dryrun-local  Show what would be done, but do nothing. Use local assets.
    -nn | -nr | --dryrun        Show what would be done, but do nothing.
    --mirrorcheck=X             X is the time (in seconds) to wait before starting the mirrorcheck.
    --repoup                    (Advanced) Force update of repository database files.
    --aurdiff                   Show PKGBUILD diff for AUR packages.
EOF
#   --versuffix=X    Append given suffix (X) to pkgver of PKGBUILD.

    test -n "$1" && exit "$1"
}

Main2()
{
    test -n "$PKGEXT" && unset PKGEXT   # don't use env vars!

    local cmd=""
    local xx yy zz
    local repoup=0
    local pkgver_suffix=""
    local reposig                    # 1 = sign repo too, 0 = don't sign repo
    local use_local_assets=0         # 0 = offer to fetch assets
    local aurdiff=0                  # 1 = show AUR diff
    local already_asked_diffs=0
    local filelist_txt
    local use_filelist               # yes or no
    local ask_timeout=60
    local AUR_DIFFS=()
    local mirror_check_wait=180
    local use_release_assets         # currently only for [endeavouros] repo

    local hook_yes="*"
    local hook_no=""                 # will contain strlen(hook_yes) spaces
    for xx in $(seq 1 ${#hook_yes}) ; do
        hook_no+=" "
    done

    # Check given parameters:
    if [ -n "$1" ] ; then
        for xx in "$@" ; do
            case "$xx" in
                --dryrun-local | -nl | -n)
                    cmd=dryrun ; use_local_assets=1 ;;
                --dryrun | -nr | -nn)
                    cmd=dryrun ;;
                --mirrorcheck=*)
                    mirror_check_wait="${xx#*=}";;
                --repoup)
                    repoup=1 ;;                  # sync repo even when no packages are built
                --aurdiff)
                    aurdiff=1 ;;
                --versuffix=*)
                    pkgver_suffix="${xx#*=}" ;;  # currently not used!
                *) Usage 0  ;;
            esac
        done
    fi

    test -r $ASSETS_CONF || DIE "cannot find local file $ASSETS_CONF"

    source $ASSETS_CONF         # local variables (with CAPITAL letters)

    filelist_txt="$ASSETSDIR/repofiles.txt"
    use_filelist="$USE_GENERATED_FILELIST"
    test -n "$use_filelist" || use_filelist="no"
    use_release_assets="$USE_RELEASE_ASSETS"
    test -n "$use_release_assets" || use_release_assets=yes

    RationalityTests            # check validity of values in $ASSETS_CONF

    Constructor

    RunPreHooks                 # may/should update local PKGBUILDs
    Assets_clone                # offer getting assets from github instead of using local ones

    # Check if we need to build new versions of packages.
    # To do that, we compare local asset versions to PKGBUILD versions.
    # Note that
    #   - Assets_clone above may have downloaded local assets from github (if user decides it is necessary)
    #   - RunPreHooks  above may/should have updated local PKGBUILDs

    local removable=()          # collected
    local removableassets=()    # collected
    local built=()              # collected
    local signed=()             # collected
    local repo_removes=()
    declare -A newv oldv
    local tmp tmpcurr
    local pkg
    local pkgdirname            # dir name for a package
    local pkgname
    local buildsavedir          # tmp storage for built packages

    echo2 "Finding package info ..."

    Pushd "$PKGBUILD_ROOTDIR"
    for xx in "${PKGNAMES[@]}" ; do
        printf2 "    %-25s : " "$(JustPkgname "$xx")"
        pkgdirname="$(ListNameToPkgName "$xx" yes)"
        test -n "$pkgdirname" || DIE "converting or fetching '$xx' failed"

        # get versions from latest PKGBUILDs
        tmp="$(PkgBuildVersion "$PKGBUILD_ROOTDIR/$pkgdirname")"
        test -n "$tmp" || DIE "PkgBuildVersion for '$xx' failed"
        newv["$pkgdirname"]="$tmp"

        # get current versions from local asset files
        pkgname="$(PkgBuildName "$pkgdirname")"
        tmpcurr="$(LocalVersion "$ASSETSDIR/$pkgname")"
        test -n "$tmpcurr" || DIE "LocalVersion for '$xx' failed"
        oldv["$pkgdirname"]="$tmpcurr"
        if [ $(vercmp "$tmp" "$tmpcurr") -gt 0 ] ; then
            echo2 "update pending to $tmp"
            WantAurDiffs "$xx"
        else
            echo2 "OK ($tmpcurr)"
        fi
    done
    if [ -n "$AUR_DIFFS" ] ; then
        Browser "${AUR_DIFFS[@]}" >& /dev/null   # xdg-open does not stop here...
    fi
    Popd

    ExplainHookMarks

    case "$cmd" in
        dryrun)
            Exit 0
            ;;
    esac

    # build if newer versions exist. When building, collect removables and builds.

    buildsavedir="$(mktemp -d "$HOME/.tmpdir.XXXXX")"

    echo2 "Check if building is needed..."
    for xx in "${PKGNAMES[@]}" ; do
        pkgdirname="$(ListNameToPkgName "$xx" no)"
        if [ $(vercmp "${newv["$pkgdirname"]}" "${oldv["$pkgdirname"]}") -gt 0 ] ; then
            echo2 "building '$pkgdirname' ..."

            # old pkg
            pkgname="$(PkgBuildName "$pkgdirname")"
            for zz in zst xz ; do
                pkg="$(ls -1 "$ASSETSDIR/$pkgname"-[0-9]*.pkg.tar.$zz 2> /dev/null)"    # $_COMPRESSOR
                test -n "$pkg" && {
                    removable+=("$pkg")
                    removable+=("$pkg".sig)

                    yy="$(basename "$pkg")"
                    removableassets+=("$yy")
                    #removableassets+=("$yy".sig)
                }
            done

            # new pkg
            pkg="$(Build "$pkgdirname" "$buildsavedir" "$PKGBUILD_ROOTDIR/$pkgdirname")"
            case "$pkg" in
                "") DIE "$pkgdirname: build failed" ;;
                *)  built+=("$pkg")               ;;
            esac
        fi
    done

    case "$SIGNER" in
        EndeavourOS) reposig=0 ;;
        *)           reposig=1 ;;
    esac

    if [ -n "$built" ] || [ "$repoup" = "1" ] ; then

        # We have something built to be sent to github, or we want to update repo to github.
        
        # now we have: removable (and removableassets), built and signed

        if [ "$PWD" != "$ASSETSDIR" ] ; then
            DIE "wrong directory: $PWD != $ASSETSDIR"
        fi

        # Move built and signed to assets dir...
        if [ -n "$built" ] ; then
            echo2 "Signing and putting it all together..."

            if [ -n "$built" ] ; then
                # sign built packages
                for pkg in "${built[@]}" ; do
                    gpg --local-user "$SIGNER" \
                        --output "$pkg.sig" \
                        --detach-sign "$pkg" || DIE "signing '$pkg' failed"
                    signed+=("$pkg.sig")
                done

                mv -i "${built[@]}" "${signed[@]}" "$ASSETSDIR"

                rm -rf $buildsavedir

                # ...and fix the variables 'built' and 'signed' accordingly.
                tmp=("${built[@]}")
                built=()
                for xx in "${tmp[@]}" ; do
                    built+=("$(basename "$xx")")
                    #built+=("$ASSETSDIR/$(basename "$xx")")
                done
                tmp=("${signed[@]}")
                signed=()
                for xx in "${tmp[@]}" ; do
                    signed+=("$(basename "$xx")")
                    #signed+=("$ASSETSDIR/$(basename "$xx")")
                done

                for xx in "${built[@]}" ; do
                    case "$xx" in
                        *.pkg.tar.$_COMPRESSOR)
                            pkgname="$(basename "$xx" | sed 's|\-[0-9].*$||')"
                            repo_removes+=("$pkgname")
                            ;;
                    esac
                done

                if [ -n "$removable" ] ; then
                    rm -f  "${removable[@]}"
                fi
                
                if [ -n "$repo_removes" ] ; then
                    # check if repo db contains any of the packages to be removed
                    yy="$(tar --list --exclude */desc -f "$ASSETSDIR/$REPONAME".db.tar.$REPO_COMPRESSOR | sed 's|-[0-9].*$||')"
                    zz=()
                    for xx in "${repo_removes[@]}" ; do
                        if [ -n "$(echo "$yy" | grep "^$xx$")" ] ; then
                            zz+=("$xx")
                        fi
                    done
                    if [ -n "$zz" ] ; then
                        # packages found in the repo db, so remove them
                        repo-remove "$ASSETSDIR/$REPONAME".db.tar.$REPO_COMPRESSOR "${zz[@]}"
                        sleep 1
                    fi
                fi

                # Put changed assets (built) to db.
                repo-add "$ASSETSDIR/$REPONAME".db.tar.$REPO_COMPRESSOR "${built[@]}"
            fi
        fi

        if [ $reposig -eq 1 ] ; then
            echo2 "Signing repo $REPONAME ..."
            repo-add --sign --key $SIGNER "$ASSETSDIR/$REPONAME".db.tar.$REPO_COMPRESSOR >/dev/null
        fi
        for xx in db files ; do
            rm -f "$ASSETSDIR/$REPONAME".$xx.tar.$REPO_COMPRESSOR.old{,.sig}
            rm -f "$ASSETSDIR/$REPONAME".$xx
            cp -a "$ASSETSDIR/$REPONAME".$xx.tar.$REPO_COMPRESSOR     "$ASSETSDIR/$REPONAME".$xx
            if [ $reposig -eq 1 ] ; then
                rm -f "$ASSETSDIR/$REPONAME".$xx.sig
                cp -a "$ASSETSDIR/$REPONAME".$xx.tar.$REPO_COMPRESSOR.sig "$ASSETSDIR/$REPONAME".$xx.sig
            fi
        done

        case "$REPONAME" in
            endeavouros)
                case "$use_release_assets" in
                     yes) ManageGithubReleaseAssets ;;
                     *)   ManageGithubNormalFiles ;;
                esac
                ;;
            *)
                case "$SIGNER" in
                    EndeavourOS) ManageGithubReleaseAssets ;;
                    *) ManageGithubReleaseAssets ;;
                esac
                ;;
        esac
    else
        echo2 "Nothing to do."
    fi

    Destructor

    ShowOldCompressedPackages   # should show nothing

    #MirrorCheck

    RunPostHooks
}

SettleDown() {
    local arg
    local ask=yes
    local msg

    for arg in "$@" ; do
        case "$arg" in
            --no-ask) ask=no ;;
            -*) WARN "$FUNCNAME: unsupported parameter '$arg'." ;;
            *) msg="$arg" ;;
        esac
    done
    test -n "$msg" && echo2 "Info: $msg"
    if [ "$ask" = "yes" ] ; then
        read2 -p "Wait, let things settle down, then press ENTER to continue: "
    fi
    echo2 ""
}

AssetCmdShow() {
    local xx
    local line="$1"            # cmd
    shift

    case "$1" in
        -*) shift ;;           # option --quietly for delete-release-assets
    esac

    line+=" for $1:"           # tag
    shift

    echo2 "$line"
    for xx in "$@" ; do
        echo2 "    $xx"
    done
}

AssetCmd() {
    local arg=""
    case "$1" in
        --no-ask) arg="$1" ; shift ;;
    esac

    AssetCmdShow "$@"
    "$@"
    if [ $? -ne 0 ] ; then
        DIE "command '$*' failed!"
    fi

    SettleDown $arg
}
AssetCmdLast() {
    local arg=""
    if [ "$tag" = "${RELEASE_TAGS[$last_tag]}" ] ; then
        arg="--no-ask"
    fi
    AssetCmd $arg "$@"
}

ManualCheckOfAssets() {
    local op="$1"
    sleep 1
    while true ; do
        hub release show -f %as%n $tag | sed 's|^.*/||' >&2
        printf2 "\n%s "  "The above assets list is the situation after $op. Is it OK (y/n)?"
        read2
        case "$REPLY" in
            [yY]*) break ;;
            *) ;;
        esac
    done
    echo2 ""
}

ManageGithubReleaseAssets() {
    echo2 "Final stop before syncing with github!"
    read2 -p "Continue (Y/n)? "
    case "$REPLY" in
        [yY]*|"") ;;
        *) Exit 0 ;;
    esac

    local last_tag=$((${#RELEASE_TAGS[@]} - 1))
    local assets

    # Github seems to have issues with some files:
    # - too long paths when adding release assets to github ??
    # - file orders --> cache issues ??

    # Remove old assets (removable) from github and local folder.

    for tag in "${RELEASE_TAGS[@]}" ; do
        assets=()

        # delete-release-assets does not need the whole file name, only unique start!
        assets+=("$REPONAME".{db,files})

        if [ -n "$removableassets" ] ; then
            #AssetCmd delete-release-assets --quietly "$tag" "${removableassets[@]}"
            assets+=("${removableassets[@]}")

            if [ -r "$filelist_txt" ] ; then
                #AssetCmd delete-release-assets --quietly "$tag" "$(basename "$filelist_txt")"
                assets+=("$(basename "$filelist_txt")")
            fi
        fi

        AssetCmd --no-ask delete-release-assets --quietly "$tag" "${assets[@]}"

        if [ -r "$filelist_txt" ] ; then
            echo2 "deleting file $filelist_txt ..."
            rm -f $filelist_txt
        fi

        ManualCheckOfAssets deletion

        # Now manage new assets.

        assets=()

        if [ "$use_filelist" = "yes" ] ; then
            # create a list of package and db files that should be also on the mirror
            pushd "$ASSETSDIR" >/dev/null
            pkg="$(ls -1 *.pkg.tar.* "$REPONAME".{db,files}{,.tar.$REPO_COMPRESSOR}{,.sig} 2>/dev/null)"
            if [ -n "$filelist_txt" ] ; then
                echo "$pkg" > "$filelist_txt"
            fi
            popd >/dev/null
        fi

        # transfer assets (built, signed and db) to github
        if [ -n "$built" ] ; then
            #AssetCmd add-release-assets "$tag" "${signed[@]}" "${built[@]}"
            assets+=("${built[@]}")
            if [ -r "$filelist_txt" ] ; then
                #AssetCmd add-release-assets "$tag" "$filelist_txt"
                assets+=("$filelist_txt")
            fi
        fi

        assets+=(
            "$REPONAME".{db,files}
            "$REPONAME".{db,files}.tar.$REPO_COMPRESSOR
        )
        if [ $reposig -eq 1 ] ; then
            assets+=("$REPONAME".{db,files}.tar.$REPO_COMPRESSOR.sig)
            assets+=("$REPONAME".{db,files}.sig)
        fi
        if [ -n "$built" ] ; then
            assets+=("${signed[@]}")
        fi

        AssetCmdLast add-release-assets "$tag" "${assets[@]}"

        ManualCheckOfAssets addition
    done
}

ManageGithubNormalFiles() {
    case "$REPONAME" in
        endeavouros) ;;
        endeavouros-testing-dev) return ;;   # TODO: remove 'return' when the repo exists!
        *) return ;;
    esac

    local workdir="$HOME/EOS/repo"
    local targetdir="$workdir/$REPONAME"
    local cp_output

    test -d "$workdir"       || DIE "work folder $workdir does not exist."
    test -d "$targetdir"     || DIE "target folder $targetdir does not exist."

    Pushd "$workdir"
    cp_output="$(cp -uv "$ASSETSDIR"/*.{db,files,xz,zst,sig} "$targetdir")"
    Popd

    if [ -n "$cp_output" ] ; then
        echo2 "$cp_output"
        printf2 "\nFiles were updated. Goto $workdir and transfer changes to github (with git commands).\n"
    else
        echo2 "Nothing more to do."
    fi
}

Main() {
    local ASSETS_CONF=assets.conf   # This file must exist in the current folder when building packages.
    local PROGNAME="$(basename "$0")"

    test "$PROGNAME" = "bashdb" && PROGNAME="${BASH_ARGV[-1]}"  # could always be like this?
    test -n "$PROGNAME" || PROGNAME="assets.make"
    test -r $ASSETS_CONF || DIE "Error: file '$PWD/$ASSETS_CONF' does not exist."

    local signer="$(  grep "^local SIGNER="   $ASSETS_CONF | cut -d '=' -f 2 | tr -d '"' | tr -d "'")"
    local reponame="$(grep "^local REPONAME=" $ASSETS_CONF | cut -d '=' -f 2 | tr -d '"' | tr -d "'")"
    local packager
    local fail=0

    local _COMPRESSOR="$(grep "^PKGEXT=" /etc/makepkg.conf | tr -d "'" | sed 's|.*\.pkg\.tar\.||')"
    local REPO_COMPRESSOR
    local xx="$(ls -1 $reponame.db.tar.{xz,zst} 2>/dev/null)"

    case "$xx" in
        *.zst) REPO_COMPRESSOR=zst ;;
        *.xz)  REPO_COMPRESSOR=xz ;;
        *) DIE "no repo db file found for '$reponame' in '$PWD'!" ;;
    esac

    if [ -z "$(grep ^PKGEXT /etc/makepkg.conf | grep zst)" ] ; then
        echo2 "/etc/makepkg.conf: use zst in variable PKGEXT"
        fail=1
    fi
    if [ -z "$(grep ^COMPRESSZST /etc/makepkg.conf | grep T0)" ] ; then
        echo2 "/etc/makepkg.conf: add -T0 -19 into variable COMPRESSZST"
        fail=1
    fi
    test $fail -eq 1 && return

    local tmpdir=$(mktemp -d FOOBAR.XXXXX)
    Pushd "$tmpdir" || DIE "Error: cannot create a temporary folder."
    tar xvf ../$reponame.db.tar.$REPO_COMPRESSOR > /dev/null
    case "$reponame" in
        endeavouros)
            export PACKAGER="$(grep -A1 PACKAGER $(ls endeavouros-mirrorlist-*/desc) | tail -n 1)"
            ;;
        endeavouros-testing-dev)
            export PACKAGER="$(grep -A1 PACKAGER $(ls eos-pkgbuild-setup-*/desc) | tail -n 1)"
            ;;
        *)
            cd "$(ls -1d * | head -n 1)"
            export PACKAGER="$(grep -A1 PACKAGER desc | tail -n 1)"
            cd ..
            ;;
    esac
    case "$PACKAGER" in
        "Unknown Packager") export PACKAGER="EndeavourOS <info@endeavouros.com>" ;;
    esac
    Popd
    rm -rf $tmpdir
    echo2 "PACKAGER: $PACKAGER"

    Main2 "$@"
}

Main "$@"
