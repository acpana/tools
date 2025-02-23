#!/usr/bin/env bash

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Copy credentials from mountpoints using su-exec
uid=$(id -u)
gid=$(id -g)

shopt -s dotglob

# Make a copy of the hosts's config secrets
# Do not copy the Docker sockets
su-exec 0:0 rsync -a --exclude=docker*.sock /config/ /config-copy/

# Set the ownershp of the host's config secrets to that of the container
su-exec 0:0 chown -R "${uid}":"${gid}" /config-copy

# Permit only the UID:GID to read the copy of the host's config secrets
chmod -R 700 /config-copy

# If a .docker/plaintext-passwords.json file exists, we are on docker_for_mac. Do the work of
# importing the plaintext-passwords.json into the .docker/config.json
if [[ -f /config-copy/.docker/plaintext-passwords.json ]]; then
	# Use jq parser to get the value of the auth key which contains the encrypted docker login credentials from
	# the plaintext-passwords.json. ("${HOME}"/.docker/plaintext-passwords.json copied from the host to
	# /config-copy/.docker/plaintext-passwords.json)
	auth_value=$(jq -r '.auths."https://index.docker.io/v1/".auth' /config-copy/.docker/plaintext-passwords.json)

	# Echo a message if the credentials are missing. It's only an issue if someone runs a
	# command expecting Docker credentials.
	if [ "$auth_value" == "null" ]; then
		echo "Missing docker credentials."
	fi

	# decode and then encode the auth value
	encode_value=$(echo "${auth_value}" | base64 --decode | base64)

	# Use jq to set the auth value for the auth key in the config.json file
	# Unfortunately jq does not support in-place editing.
	# This credential will be used to push the repositories' docker images.
	# Also remove the credsStore key to prevent commands from trying to run
	# programs on the host, you can't from the container, to retrieve creds.
	jq --arg auth "${encode_value}" '.auths."https://index.docker.io/v1/".auth=$auth' /config-copy/.docker/config.json > /config-copy/.docker/config-tmp.json
	jq 'del(.credsStore)' /config-copy/.docker/config-tmp.json > /config-copy/.docker/config.json
fi

# Add user based upon passed UID. this means Istio need no longer host mount /etc/passwd
# nor /etc/group.
# Skip adding if run as root.
if [[ "${uid}" -ne 0 ]]; then
  su-exec 0:0 useradd --uid "${uid}" --system user
fi

# Set ownership of /home to UID:GID
su-exec 0:0 chown "${uid}":"${gid}" /home

# Copy the config secrets without changing permissions nor ownership for
# consumption by tooolchains
cp -R /config-copy/* /home/

exec "$@"
