#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -o pipefail

root_dir="$PWD"
man_file=${root_dir}/manifest_commands.sh
source_prefix="adoptopenjdk"
source_repo="openjdk"
version="9"

source ./common_functions.sh

if [ ! -z "$1" ]; then
	version=$1
	if [ ! -z "$(check_version $version)" ]; then
		echo "ERROR: Invalid Version"
		echo "Usage: $0 [${supported_versions}]"
		exit 1
	fi
fi

# Where is the manifest tool installed?"
# Manifest tool (docker with manifest support) needs to be added from here
# https://github.com/clnperez/cli
# $ cd /opt/manifest_tool
# $ git clone -b manifest-cmd https://github.com/clnperez/cli.git
# $ cd cli
# $ make -f docker.Makefile cross
manifest_tool_dir="/opt/manifest_tool"
manifest_tool=${manifest_tool_dir}/cli/build/docker

if [ ! -f ${manifest_tool} ]; then
	echo
	echo "ERROR: Docker with manifest support not found at path ${manifest_tool}"
	exit 1
fi

# Find the latest version and get the corresponding shasums
./generate_latest_sums.sh ${version}

# source the hotspot and openj9 shasums scripts
supported_jvms=""
if [ -f hotspot_shasums_latest.sh ]; then
	source ./hotspot_shasums_latest.sh
	supported_jvms="hotspot"
fi
if [ -f openj9_shasums_latest.sh ]; then
	source ./openj9_shasums_latest.sh
	supported_jvms="${supported_jvms} openj9"
fi

# Set the params based on the arch we are on currently
machine=`uname -m`
case $machine in
aarch64)
	arch="aarch64"
	oses="ubuntu"
	package="jdk"
	;;
ppc64le)
	arch="ppc64le"
	oses="ubuntu"
	package="jdk"
	;;
s390x)
	arch="s390x"
	oses="ubuntu"
	package="jdk"
	;;
x86_64)
	arch="x86_64"
	oses="ubuntu alpine"
	package="jdk"
	;;
*)
	echo "ERROR: Unsupported arch:${machine}, Exiting"
	exit 1
	;;
esac

# Check if a given docker image exists on the server.
# This script errors out if the image does not exist.
function check_image() {
	lrepo=$1
	stag=$2

	tag=$(echo ${stag} | sed 's/%/-/g')
	echo -n "INFO: Pulling image: ${lrepo}:${tag}..."
	docker pull ${lrepo}:${tag} >/dev/null
	if [ $? != 0 ]; then
		echo "ERROR: Docker Image ${lrepo}:${tag} not found on hub.docker\n"
		exit 1
	fi
	echo "done"
}

# build a set of valid docker image tags based on the VM and the supported arches.
function build_tag_list() {
	sums=$1
	os=$2
	rel=$3
	btype=$4

	if [ ${os} == "ubuntu" ]; then
		supported_arches=$(get_arches ${sums})
	else
		supported_arches="x86_64"
	fi
	arch_tags=""
	for sarch in ${supported_arches}
	do
		# Have '%' as FS to retrieve the OS and Rel info later.
		if [ "${btype}" == "nightly" ]; then
			tag=${sarch}%${os}%${rel}%nightly
		else
			tag=${sarch}%${os}%${rel}
		fi
		arch_tags="${arch_tags} ${tag}"
	done
	echo "${arch_tags}"
}

function print_annotate_cmd() {
	main_tag=$1
	arch_tag=$2

	march=$(echo ${arch_tag} | awk -F':' '{ print $2 }' | awk -F'-' '{ print $1 }')
	if [ ${march} == "x86_64" ]; then
		march="amd64"
	fi
	echo "${manifest_tool} manifest annotate ${main_tag} ${arch_tag} --os linux --arch ${march}" >> ${man_file}
}

# Space separated list of tags in parameter array
function print_manifest_cmd() {
	atags=$@

	main_tags=""
	# Get the OS and Release info from the tag list.
	declare -a tarr=( ${atags} )
	os="$(echo ${tarr[0]} | awk -F':' '{ print $2 }' | awk -F'%' '{ print $2 }')"
	release="$(echo ${tarr[0]} | awk -F':' '{ print $2 }' | awk -F'%' '{ print $3 }')"
	btype="$(echo ${tarr[0]} | awk -F':' '{ print $2 }' | awk -F'%' '{ print $NF }')"
	# Remove the '%' and add back '-' as the FS
	arch_tags=$(echo ${atags} | sed 's/%/-/g')

	# For ubuntu, :$release and :latest are the additional generic tags
	# For alpine, :$release-alpine and :alpine are the additional generic tags
	if [ ${os} == "ubuntu" ]; then
		if [ "${btype}" == "nightly" ]; then
			main_tags=${trepo}:${release}-nightly
			main_tags="${main_tags} ${trepo}:nightly"
		else
			main_tags=${trepo}:${release}
			main_tags="${main_tags} ${trepo}:latest"
		fi
	else
		if [ "${btype}" == "nightly" ]; then
			main_tags=${trepo}:${release}-alpine-nightly
			main_tags="${main_tags} ${trepo}:alpine-nightly"
		else
			main_tags=${trepo}:${release}-alpine
			main_tags="${main_tags} ${trepo}:alpine"
		fi
	fi

	for main_tag in ${main_tags}
	do
		echo "${manifest_tool} manifest create ${main_tag} ${arch_tags}" >> ${man_file}
		declare -a tarr=( ${arch_tags} )
		for i in `seq 0 $(( ${#tarr[@]} - 1 ))`
		do
			print_annotate_cmd ${main_tag} ${tarr[$i]}
		done
		echo "${manifest_tool} manifest push ${main_tag}" >> ${man_file}
		echo >> ${man_file}
	done
}

function print_tags() {
	mantags="$(declare -p $1)";
	eval "declare -A mtags="${mantags#*=};
	for repo in ${!mtags[@]}
	do
		create_cmd=""
		declare -a tarr=( ${mtags[$repo]} )
		for i in `seq 0 $(( ${#tarr[@]} - 1 ))`
		do
			trepo=${source_prefix}/${repo}
			check_image ${trepo} ${tarr[$i]}
			create_cmd="${create_cmd} ${trepo}:${tarr[$i]}"
		done
		print_manifest_cmd ${create_cmd}
	done
}

# Valid image tags
#adoptopenjdk/openjdk${version}:${arch}-${os}-${rel} ${rel} latest ${rel}-nightly nightly
#adoptopenjdk/openjdk${version}:${rel}-alpine alpine ${rel}-alpine-nightly alpine-nightly
#adoptopenjdk/openjdk${version}-openj9:${arch}-${os}-${rel} ${rel} latest ${rel}-nightly nightly
#adoptopenjdk/openjdk${version}-openj9:${rel}-alpine alpine ${rel}-alpine-nightly alpine-nightly
#
declare -A manifest_tags_ubuntu
declare -A manifest_tags_alpine

declare -A manifest_tags_ubuntu_nightly
declare -A manifest_tags_alpine_nightly

for vm in ${supported_jvms}
do
	for buildtype in ${build_types}
	do
		shasums="${package}"_"${vm}"_"${version}"_"${buildtype}"_sums
		jverinfo=${shasums}[version]
		eval jrel=\${$jverinfo}
		rel=$(echo $jrel | sed 's/+/./')

		if [ "${vm}" == "hotspot" ]; then
			srepo=${source_repo}${version}
		else
			srepo=${source_repo}${version}-${vm}
		fi
		for os in ${oses}
		do
			echo -n "INFO: Building tag list for [${vm}] and [${os}] for build type [${buildtype}]..."
			tag_list=$(build_tag_list ${shasums} ${os} ${rel} ${buildtype})
			if [ $os == "ubuntu" ]; then
				if [ "${buildtype}" == "nightly" ]; then
					manifest_tags_ubuntu_nightly[${srepo}]=${tag_list}
				else
					manifest_tags_ubuntu[${srepo}]=${tag_list}
				fi
			elif [ $os == "alpine" ]; then
				if [ "${buildtype}" == "nightly" ]; then
					manifest_tags_alpine_nightly[${srepo}]=${tag_list}
				else
					manifest_tags_alpine[${srepo}]=${tag_list}
				fi
			else
				echo "ERROR: Unsupported OS: ${os}"
				exit 1
			fi
			echo "done"
		done
	done
done

# Populate the script to create the manifest list
echo "#!/bin/bash" > ${man_file}
echo  >> ${man_file}

print_tags manifest_tags_ubuntu
print_tags manifest_tags_ubuntu_nightly
print_tags manifest_tags_alpine
print_tags manifest_tags_alpine_nightly

chmod +x ${man_file}
echo "INFO: Manifest commands in file: ${man_file}"
