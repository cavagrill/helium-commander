#!/usr/bin/env bash

set -o errexit
set -o nounset

declare -r debug='false'
declare -r tmpfile_file="/tmp/publish.$$.tmpfiles"

function make_temp_file
{
    local template="${1:-publish.$$.XXXXXX}"
    if [[ $template != *XXXXXX ]]
    then
        template="$template.XXXXXX"
    fi
    local tmp=$(mktemp -t "$template")
    echo "$tmp" >> "$tmpfile_file"
    echo "$tmp"
}

function now
{
    date '+%Y-%m-%d %H:%M:%S'
}

function pwarn
{
    echo "$(now) [warning]: $@" 1>&2
}

function perr
{
    echo "$(now) [error]: $@" 1>&2
}

function pinfo
{
    echo "$(now) [info]: $@"
}

function pdebug
{
    if [[ $debug == 'true' ]]
    then
        echo "$(now) [debug]: $@"
    fi
}

function errexit
{
    perr "$@"
    exit 1
}

function onexit
{
    if [[ -f $tmpfile_file ]]
    then
        for tmpfile in $(< $tmpfile_file)
        do
            pdebug "removing temp file $tmpfile"
            rm -f $tmpfile
        done
        rm -f $tmpfile_file
    fi
}

function gh_publish {
    if [[ -z $version_string ]]
    then
        errexit 'gh_publish: version_string required'
    fi

    # NB: no 'v' here at start of version_string
    local -r package_name="helium-commander-$version_string.tar.gz"
    local -r package="./dist/helium-commander-$version_string.tar.gz"
    if [[ ! -s $package ]]
    then
        errexit "gh_publish: expected to find $package in dist/"
    fi

    # NB: we use a X.Y.Z tag
    local -r release_json="{
        \"tag_name\" : \"$version_string\",
        \"name\" : \"Helium Commander  $version_string\",
        \"body\" : \"helium-commander $version_string\nhttps://github.com/helium/helium-commander/blob/master/CHANGES\",
        \"draft\" : false,
        \"prerelease\" : $is_prerelease
    }"

    pdebug "Release JSON: $release_json"

    local curl_content_file="$(make_temp_file)"
    local curl_stdout_file="$(make_temp_file)"
    local curl_stderr_file="$(make_temp_file)"

    curl -4so $curl_content_file -w '%{http_code}' -XPOST \
        -H "Authorization: token $(< $github_api_key_file)" -H 'Content-type: application/json' \
        'https://api.github.com/repos/helium/helium-commander/releases' -d "$release_json" 1> "$curl_stdout_file" 2> "$curl_stderr_file"
    if [[ $? != 0 ]]
    then
        errexit "curl error exited with code: '$?' see '$curl_stderr_file'"
    fi

    local -i curl_rslt="$(< $curl_stdout_file)"
    if (( curl_rslt == 422 ))
    then
        pwarn "Release in GitHub already exists! (http code: '$curl_rslt')"
        curl -4so $curl_content_file -w '%{http_code}' -XGET \
            -H "Authorization: token $(< $github_api_key_file)" -H 'Content-type: application/json' \
            "https://api.github.com/repos/helium/helium-commander/releases/tags/$version_string" 1> "$curl_stdout_file" 2> "$curl_stderr_file"
        if [[ $? != 0 ]]
        then
            errexit "curl error exited with code: '$?' see '$curl_stderr_file'"
        fi
    elif (( curl_rslt != 201 ))
    then
        errexit "Creating release in GitHub failed with http code '$curl_rslt'"
    fi

    if [[ ! -s $curl_content_file ]]
    then
        errexit 'no release info to parse for asset uploads'
    fi

    # "upload_url": "https://uploads.github.com/repos/helium/helium-commander/releases/1115734/assets{?name,label}"
    # https://uploads.github.com/repos/helium/helium-commander/releases/1115734/assets{?name,label}
    local -r upload_url_with_name=$(perl -ne 'print qq($1\n) and exit if /"upload_url"[ :]+"(https:\/\/[^"]+)"/' "$curl_content_file")
    local -r upload_url="${upload_url_with_name/\{?name,label\}/?name=$package_name}"

    local curl_content_file="$(make_temp_file)"
    local curl_stdout_file="$(make_temp_file)"
    local curl_stderr_file="$(make_temp_file)"

    curl -4so $curl_content_file -w '%{http_code}' -XPOST \
        -H "Authorization: token $(< $github_api_key_file)" -H 'Content-type: application/x-compressed, application/x-tar' \
        "$upload_url" --data-binary "@$package" 1> "$curl_stdout_file" 2> "$curl_stderr_file"
    if [[ $? != 0 ]]
    then
        errexit "curl error exited with code: '$?' see '$curl_stderr_file'"
    fi

    curl_rslt="$(< $curl_stdout_file)"
    if (( curl_rslt != 201 ))
    then
        errexit "Uploading release assets to GitHub failed with http code '$curl_rslt'"
    fi
}

trap onexit EXIT

declare -r version_string="${1:-unknown}"

# https://www.python.org/dev/peps/pep-0440/
if [[ ! $version_string =~ ^[0-9].[0-9].[0-9]([abcr]+[0-9]+)?$ ]]
then
    errexit 'first argument must be valid version string in X.Y.Z, X.Y.ZaN, X.Y.ZbN or X.Y.ZrcN format'
fi

is_prerelease='false'
if [[ $version_string =~ ^[0-9].[0-9].[0-9][abcr]+[0-9]+$ ]]
then
    pinfo "publishing pre-release version: $version_string"
    is_prerelease='true'
else
    pinfo "publishing version $version_string"
fi

declare -r current_branch="$(git rev-parse --abbrev-ref HEAD)"

if [[ $debug == 'false' && $is_prerelease == 'false' && $current_branch != 'master' ]]
then
    errexit 'publish must be run on master branch'
fi

declare -r github_api_key_file="$HOME/.ghapi"
if [[ ! -s $github_api_key_file ]]
then
    errexit "please save your GitHub API token in $github_api_key_file"
fi

# Validate commands
if ! hash curl 2>/dev/null
then
    errexit "'curl' must be in your PATH"
fi

validate=${2:-''}
if [[ $validate == 'validate' ]]
then
    exit 0
fi

gh_publish
