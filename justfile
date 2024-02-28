# Expect the following structure by default:
# 	
# - /                   # root dir
# - /justfile           # this file
# - /mariadb-server     # server git checkout
# - /build-mdb-server   # build target directory
# - /local-install      # location of data, plugin, and socket files

set dotenv-load := true

source_dir := env("MARIA_SOURCE_DIR", justfile_directory() / "mariadb-server")
build_dir := env("MARIA_BUILD_DIR", justfile_directory() / "build-mdb-server")
data_dir := env("MARIA_DATA_DIR", justfile_directory() / "local-install" / "data")
plugin_dir := env("MARIA_PLUGIN_DIR", justfile_directory() / "local-install" / "plugins")
socket := env("MARIA_SOCKET", justfile_directory() / "local-install" / "mdb.sock")

vscode_config_dir := source_dir / ".vscode"
cmake_dir_args := '"-B' + build_dir + '" "-S' + source_dir + '"'
cflags_disable_macos_warnings := " \
  -Wno-deprecated-non-prototype \
  -Wno-inconsistent-missing-override \
  -Wno-unused-but-set-variable \
  -Wno-deprecated-declarations \
  -Wno-sign-compare \
"
cflags := if os() == "macos" { cflags_disable_macos_warnings } else { "" }

default:
	@echo os: {{os()}} arch: {{arch()}}
	just --list

# Perform basic configuration
configure *EXTRA_CMAKE_ARGS:
	#!/bin/sh
	set -eau
	
	# Manually handle caching for this recipe
	cachekey={{ sha256(EXTRA_CMAKE_ARGS + cmake_dir_args + cflags) }}
	cachekey_file="{{ build_dir }}/cachekey-configure"
	[ "$(cat "$cachekey_file" 2>/dev/null || echo "")" = "$cachekey" ] &&
		echo "skipping configuration (unchanged)" &&
		exit 0
	
	cmake {{ cmake_dir_args }} -G Ninja \
		-DCMAKE_BUILD_TYPE=Debug \
		-DCMAKE_C_COMPILER=clang \
		-DCMAKE_CXX_COMPILER=clang++ \
		"-DCMAKE_C_FLAGS={{ cflags }}" \
		"-DCMAKE_CXX_FLAGS={{ cflags }}" \
		-DCMAKE_EXPORT_COMPILE_COMMANDS=true \
		-DPLUGIN_MROONGA=NO \
		-DPLUGIN_ROCKSDB=NO \
		-DPLUGIN_SPIDER=NO \
		-DPLUGIN_SPHINX=NO \
		-DPLUGIN_TOKUDB=NO \
		{{ EXTRA_CMAKE_ARGS }}

	printf "$cachekey" > "$cachekey_file"

# -DCMAKE_C_FLAGS="-fuse-ld=mold"
# -DCMAKE_CXX_FLAGS="-fuse-ld=mold"
# -DCMAKE_C_COMPILER_LAUNCHER=sccache \
# -DCMAKE_CXX_COMPILER_LAUNCHER=sccache \
# -DRUN_ABI_CHECK=NO \

build *EXTRA_CMAKE_ARGS: configure
	cmake --build "{{ build_dir }}" {{ EXTRA_CMAKE_ARGS }}

# Just delete and recreate the build directory
clean:
	rm -rf "{{ build_dir }}"
	mkdir "{{ build_dir }}"

# Perform install to a local database
install-local: build
	mkdir -p "{{ data_dir }}"
	mkdir -p "{{ plugin_dir }}"
	touch "{{ socket }}"

	{{ build_dir }}/scripts/mariadb-install-db \
	    --srcdir={{ source_dir }} \
	    --datadir={{ data_dir }} \
	    --builddir={{ build_dir }}

# Run the server (includes gdb and clevis test argument)
run *EXTRA_ARGS:
	"{{ build_dir }}/sql/mariadbd" \
		"--datadir={{ data_dir }}" \
		"--socket={{ socket }}" \
		"--plugin-dir={{ plugin_dir }}" \
		"--plugin-maturity=experimental" \
		"--loose-clevis-key-management-tang-server=localhost:11697" \
		--plugin-load \
		"--gdb" \
		{{ EXTRA_ARGS }}

# Connect to the database at a socket
connect:
	mariadb --socket "{{ socket }}"

# Shortcut for `mtr`
alias t := mtr

# Invoke the MTR test runner. Parallelism and three retries are enabled by default.
mtr *ARGS: build
	"{{ build_dir }}/mysql-test/mtr" \
		--parallel={{ num_cpus() }} \
		--retry=3 \
		{{ ARGS }}

# Symlink plugins to the relevant directory
link-plugins:
	#!/usr/bin/env bash
	set -eau
	dir_dbg="{{ build_dir }}/rust_target/debug"
	dir_rel="{{ build_dir }}/rust_target/release"

	if [ -d "$dir_dbg" ]; then
		ls -d "$dir_dbg"/* | grep -E '\.(so|dylib|dll)$' | xargs realpath |
			xargs -IINFILE ln -sfw INFILE {{ plugin_dir }}
	fi

	if [ -d "$dir_rel" ]; then
		ls -d "$dir_rel"/* | grep -E '\.(so|dylib|dll)$' | xargs realpath |
			xargs -IINFILE ln -sfw INFILE {{ plugin_dir }}
	fi

	find "{{ build_dir }}/storage" "{{ build_dir }}/plugin" -name '*.so' |
		xargs realpath | xargs -IINFILE ln -sfw INFILE {{ plugin_dir }}

	# Find symlink files with MacOS extensions to rename
	find "{{ plugin_dir }}" -type l -maxdepth 1 -name '*.dylib' |
		while read -r file; do
		    mv -- "$file" "${file%.dylib}.so"
		done


# Symlink configuration so C language servers work correctly
configure-clangd: configure
	#!/usr/bin/env sh
	dst="{{ build_dir }}/compile_commands.json"
	if ! [ -f "$dst" ]; then
		echo "creating compile_commands symlink"
		ln -is "$dst" "{{ source_dir }}"
	else
		echo "skipping compile_commands symlink (already exists)"
	fi

# Write configuration for debugging via vscode
configure-vscode:
	#!/usr/bin/env sh
	mkdir -p "{{ vscode_config_dir }}"
	
	echo '{
	    "version": "0.2.0",
	    "configurations": [
	        {
	            "name": "Launch with LLDB",
	            "type": "lldb",
	            "request": "launch",
	            "program": "{{ build_dir }}/sql/mariadbd",
	            "args": [
	                "--datadir={{ data_dir }}",
	                "--socket={{ socket }}",
	                "--plugin-dir={{ plugin_dir }}",
	                "--plugin-maturity=experimental",
	                "--loose-clevis-key-management-tang-server=localhost:11697",
	                "--gdb"
	            ]
	        }
	    ]
	}' > {{ vscode_config_dir }}/launch.json

# Configure vscode and clangd
configure-ides: configure-vscode configure-clangd
	
