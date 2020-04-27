#!/usr/bin/env bash

BRIDGE_IDENTITY="idf_cactus_jumphost_bridges_"
builder_image=cactus/dib:latest
dib_name=cactus_image_builder

function imagedir {
  echo ${STORAGE_DIR}/${cluster_version}
}

function diskdir {
  echo ${STORAGE_DIR}/${PREFIX}_${cluster_version}
}

function __get_bridges {
  set +x
  compgen -v ${BRIDGE_IDENTITY} |
  while read var; do {
    echo ${var#${BRIDGE_IDENTITY}}
  }
  done || true
  [[ "${CI_DEBUG}" =~ (false|0) ]] || set -x
}

function update_bridges {
  read -r -a BR_NAMES <<< $(__get_bridges)
  for br in "${BR_NAMES[@]}"; do
    old=$(eval echo "\$${BRIDGE_IDENTITY}${br}")
    eval "${BRIDGE_IDENTITY}${br}=${PREFIX}_${old}"
  done
}

function prepare_networks {
  [[ ! "${BR_NAMES[@]}" =~ "admin" ]] && {
    notify_n "[ERR] Bridge admin must be defined\n" 2
    exit 1
  }

  # Expand network templates
  for tp in "${TEMPLATE_DIR}/"*.template; do
    eval "cat <<-EOF
      $(<"${tp}")
EOF" 2> /dev/null > "${TMP_DIR}/$(basename ${tp%.template})"
  done
}

function build_images {
  local sshpub="${SSH_KEY}.pub"

  [[ "$(docker images -q ${builder_image} 2>/dev/null)" != "" ]] || {
    echo "build diskimage_builder image... "
    pushd ${REPO_ROOT_PATH}/docker/dib
    docker build -t ${builder_image} .
    [[ 0 != $? ]] && {
      echo "Build diskimage_builder image ${builder_image} failed"
      exit 1
    }
    popd
  }

  echo "Start DIB console named ${dib_name} service ... "
  docker run -it \
           --name ${dib_name} \
           -v ${STORAGE_DIR}:/imagedata \
           -v ${SSH_KEY}.pub:/work/rsa.pub \
           --privileged \
           --rm \
           ${builder_image} \
           bash /work/create_image.sh ${cluster_version} ${cluster_image}
  [[ 0 != $? ]] && {
    echo "Create base images failed"
    exit 1
  }
}

function cleanup_vms {
  # clean up existing nodes
  for node in $(virsh list --name | grep -P "${PREFIX}_"); do
    virsh destroy "${node}"
  done
  for node in $(virsh list --name --all | grep -P "${PREFIX}_"); do
    virsh domblklist "${node}" | awk '/^.da/ {print $2}' | \
      xargs --no-run-if-empty -I{} sudo rm -f {}
    # TODO command 'undefine' doesn't support option --nvram
    virsh undefine "${node}" --remove-all-storage
    ip=$(get_admin_ip ${node##${PREFIX}_})
    sudouser_exc "ssh-keygen -R ${ip}"
    ssh-keygen -R ${ip} || true
  done
}

function prepare_vms {
  mkdir $(diskdir) || true

  # Create vnode images and resize OS disk image for each foundation node VM
  for vnode in "${vnodes[@]}"; do
    image="$(diskdir)/${vnode}.qcow2"
    echo "preparing for vnode: [${vnode}]"
    cp "$(imagedir)/${cluster_image}" "${image}"
    disk_capacity="nodes_${vnode}_node_disk"
    qemu-img resize ${image} ${!disk_capacity}
    virt-customize -a ${image} --hostname "${vnode}.${PREFIX}" --run-command "sed -i \"s/cactus:x:1000:1000::\/home\/cactus:\/bin\/sh/cactus:x:1000:1000::\/home\/cactus:\/bin\/bash/g\" /etc/passwd"
  done
}

function cleanup_networks {
  for net in $(virsh net-list --name | grep "${PREFIX}_"); do
    virsh net-destroy "${net}" || true
    virsh net-undefine "${net}"
  done
}

function create_networks {

  # create required networks
  for br in "${BR_NAMES[@]}"; do
    net=$(eval echo "\$${BRIDGE_IDENTITY}${br}")
    # in case of custom network, host should already have the bridge in place
    if [ -f "${TMP_DIR}/net_${br}.xml" ] && [ ! -d "/sys/class/net/${net}/bridge" ]; then
      virsh net-define "${TMP_DIR}/net_${br}.xml"
      virsh net-autostart "${net}"
      virsh net-start "${net}"
    fi
  done
}

function create_vms {
  cpu_pass_through=$1; shift

  # AArch64: prepare arch specific arguments
  local virt_extra_args=""
  if [ "$(uname -i)" = "aarch64" ]; then
    # No Cirrus VGA on AArch64, use virtio instead
    virt_extra_args="$virt_extra_args --video=virtio"
  fi

  # create vms with specified options
  for vnode in "${vnodes[@]}"; do
    # prepare network args
    net_args=""
    for br in "${BR_NAMES[@]}"; do
      net=$(eval echo "\$${BRIDGE_IDENTITY}${br}")
      net_args="${net_args} --network bridge=${net},model=virtio"
    done

    [ ${cpu_pass_through} -eq 1 ] && \
    cpu_para="--cpu host-passthrough" || \
    cpu_para=""

    [[ $(eval echo "\$nodes_${vnode}_node_features") =~ hugepage ]] && hugepage="--memorybacking hugepages=yes" || hugepage=""

    # shellcheck disable=SC2086
    virt-install --name "${PREFIX}_${vnode}" \
    --memory $(eval echo "\$nodes_${vnode}_node_memory") ${hugepage} \
    --vcpus $(eval echo "\$nodes_${vnode}_node_cpus") \
    ${cpu_para} --accelerate ${net_args} \
    --disk path="${STORAGE_DIR}/${PREFIX}_${cluster_version}/${vnode}.qcow2",format=qcow2,bus=virtio,cache=none,io=native \
    --os-type linux --os-variant none \
    --boot hd --vnc --console pty --autostart --noreboot \
    --noautoconsole \
    ${virt_extra_args}
  done
}

function update_network {
  net=${1}
  for vnode in "${vnodes[@]}"; do
    local br=$(eval echo "\$idf_cactus_jumphost_bridges_${net}")
    local guest="${PREFIX}_${vnode}"
    local ip=$(eval "get_${net}_ip ${vnode}")
    local mac=$(virsh domiflist ${guest} 2>&1 | grep ${br} | awk '{print $5; exit}')
    virsh net-update "${br}" add ip-dhcp-host \
      "<host mac='${mac}' name='${guest}' ip='${ip}'/>" --live --config
  done
}

function start_vms {
  # start vms
  for node in "${vnodes[@]}"; do
    virsh start "${PREFIX}_${node}"
    sleep $((RANDOM%5+1))
  done
}

function check_connection {
  local total_attempts=60
  local sleep_time=5

  set +e
  echo '[INFO] Attempting to get into master ...'

  # wait until ssh on master is available
  # shellcheck disable=SC2034
  for vnode in "${vnodes[@]}"; do
    if is_master ${vnode}; then
      for attempt in $(seq "${total_attempts}"); do
        ssh_exc $(get_admin_ip ${vnode}) uptime
        case $? in
          0) echo "${attempt}> Success"; break ;;
          *) echo "${attempt}/${total_attempts}> master ain't ready yet, waiting for ${sleep_time} seconds ..." ;;
        esac
        sleep $sleep_time
      done
    fi
  done
  set -e
}

function cleanup_dib {
  docker ps -a | grep ${dib_name} | awk '{print $1}' | xargs -I {} docker rm -f {} &>/dev/null
  docker rmi ${builder_image} || true
  rm -fr $(imagedir) || true
}

function cleanup_sto {
  rm -fr $(diskdir) || true
}

function cleanup_img {
  rm -fr $(imagedir) || true
  rm -fr $(diskdir) || true
}
