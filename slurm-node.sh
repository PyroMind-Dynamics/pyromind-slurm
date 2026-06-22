#!/bin/bash


## 四个参数 必须设置
PKG_ROOT_PATH="/root/pyromind-slurm"
SLURM_DATA_STORE_BASE="/root/slurm_data"
MASTER_POD_ID="ee3a4ed8314f"
CONTROL_MACHINE="192.168.62.26"



echo "=========================================="
echo "Slurm Configuration Generator"
echo "=========================================="

pkill slurmd
pkill munged 
HOST=$(hostname)
echo "Detected hostname: ${HOST}"


export PATH=/usr/local/nvidia/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/nvidia/lib64:$LD_LIBRARY_PATH

CLUSTER_NAME="jupyter-deployment-${MASTER_POD_ID}-0"
SLURM_BASE_DATA_DIR="${SLURM_DATA_STORE_BASE}/${HOST}"
PKG_ROOT_PATH_BASE=$PKG_ROOT_PATH/base
PKG_ROOT_PATH_SLURM=$PKG_ROOT_PATH/slurm

cd $PKG_ROOT_PATH_BASE && dpkg -i libsigsegv2_*.deb && dpkg -i gawk_*.deb && dpkg -i *.deb && apt-get install -f -y 


# 定义目录列表（使用 | 作为分隔符，避免与路径冲突）
directories="${SLURM_BASE_DATA_DIR}/munge:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurmd/spool:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/spool:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/run:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/log:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/data:root:root:755|\
/etc/slurm:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/log/slurm:root:root:755"

# 设置 IFS 为 | 分割
OLD_IFS="$IFS"
IFS='|'
set -- $directories
IFS="$OLD_IFS"

# 处理每个目录
for dir_config in "$@"; do
  # 使用 cut 或 awk 解析
  dir_path=$(echo "$dir_config" | cut -d':' -f1)
  owner=$(echo "$dir_config" | cut -d':' -f2)
  group=$(echo "$dir_config" | cut -d':' -f3)
  perm=$(echo "$dir_config" | cut -d':' -f4)
  
  # 检查目录是否存在
  if [ -d "$dir_path" ]; then
    echo "目录已存在，跳过: $dir_path"
  else
    echo "创建目录: $dir_path"
    mkdir -p "$dir_path"
    chown "$owner:$group" "$dir_path"
    chmod "$perm" "$dir_path"
    echo "已设置权限: $owner:$group $perm"
  fi
done

# ${SLURM_BASE_DATA_DIR}/munge/munge.key 不存在这个目录 就报错退出
if [ ! -d "${SLURM_BASE_DATA_DIR}/munge" ]; then
    echo "Error: ${SLURM_BASE_DATA_DIR}/munge not found"
    echo "Please copy munge directory from master node first"
    exit 1
fi

mkdir -p /run/munge
chmod 755 /run/munge
chmod 755 "${SLURM_BASE_DATA_DIR}"
chmod 600 "${SLURM_BASE_DATA_DIR}/munge/munge.key"

if ! pgrep -x "munged" > /dev/null; then
    munged \
      --key-file "${SLURM_BASE_DATA_DIR}/munge/munge.key" \
      --seed-file "${SLURM_BASE_DATA_DIR}/munge/munged.seed" \
      --log-file "${SLURM_BASE_DATA_DIR}/munge/munged.log" \
      --pid-file "${SLURM_BASE_DATA_DIR}/munge/munged.pid"
else
    echo "munged is already running"
fi

cd $PKG_ROOT_PATH_SLURM && dpkg -i *.deb && dpkg --configure -a   &&  dpkg -i *.deb &&  apt-get install -f -y

SLURMD_INFO=$(slurmd -C 2>/dev/null)
if [ -z "$SLURMD_INFO" ]; then
    echo "❌ Error: slurmd -C failed. Is slurmd installed?"
    exit 1
fi

# 提取 CPU 数量
CPUS=$(echo "$SLURMD_INFO" | grep -oP 'CPUs=\K[0-9]+')
if [ -z "$CPUS" ]; then
    CPUS=16
fi

# 提取内存 (MB)
REAL_MEMORY=$(echo "$SLURMD_INFO" | grep -oP 'RealMemory=\K[0-9]+')
if [ -z "$REAL_MEMORY" ]; then
    REAL_MEMORY=128648
fi


echo "从 slurmd -C 获取: CPUs=${CPUS}, RealMemory=${REAL_MEMORY} MB"
# ============================================
# 生成 slurm.conf
# ============================================
cat > /etc/slurm/slurm.conf << SLURM_EOF
ClusterName=${CLUSTER_NAME}
ControlMachine=${CONTROL_MACHINE}

SlurmUser=root
AuthType=auth/munge

ProctrackType=proctrack/linuxproc
TaskPlugin=task/none

SlurmdSpoolDir=${SLURM_BASE_DATA_DIR}
SlurmdLogFile=${SLURM_BASE_DATA_DIR}/slurmd.log

SlurmdPort=6818
SlurmdTimeout=300
SlurmctldTimeout=300

SlurmdParameters=DynamicModules,AllowDynamicGres
SelectType=select/cons_tres

GresTypes=gpu
SLURM_EOF

echo "✅ slurm.conf generated!"


# ============================================
# 生成 gres.conf
# ============================================

# ============================================
# 检测 GPU 设备
# ============================================
# 方法1：通过 /dev/nvidia* 检测
GPU_DEVICES=$(ls /dev/nvidia[0-9]* 2>/dev/null | sort)

# 如果 /dev/nvidia* 没找到，尝试通过 nvidia-smi 检测
if [ -z "$GPU_DEVICES" ]; then
    if command -v nvidia-smi &> /dev/null && nvidia-smi -L &> /dev/null; then
        GPU_COUNT=$(nvidia-smi -L | wc -l)
        if [ "$GPU_COUNT" -gt 0 ]; then
            GPU_DEVICES=""
            for i in $(seq 0 $((GPU_COUNT-1))); do
                DEV="/dev/nvidia${i}"
                if [ -e "$DEV" ]; then
                    GPU_DEVICES="${GPU_DEVICES} ${DEV}"
                fi
            done
        fi
    fi
fi

# ============================================
# 如果检测到 GPU，生成 gres.conf
# ============================================
if [ -n "$GPU_DEVICES" ]; then
    # 获取 GPU 型号
    if command -v nvidia-smi &> /dev/null && nvidia-smi -L &> /dev/null; then
        GPU_TYPE=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^NVIDIA //' | awk '{print $1}')
    fi
    [ -z "$GPU_TYPE" ] && GPU_TYPE="nvidia"
    
    # 生成 gres.conf
    cat > /etc/slurm/gres.conf << GRES_EOF
# Auto-generated gres.conf
# Hostname: ${HOST}
# GPU Type: ${GPU_TYPE}
# Generated at: $(date)
GRES_EOF
    
    for DEV in $GPU_DEVICES; do
        echo "NodeName=${HOST} Name=gpu Type=${GPU_TYPE} File=${DEV} AutoDetect=off" >> /etc/slurm/gres.conf
    done
    
    echo "✅ gres.conf generated with $(echo $GPU_DEVICES | wc -w) GPU(s)"
    cat /etc/slurm/gres.conf
else
    # 没有 GPU，删除 gres.conf（如果存在）
    if [ -f /etc/slurm/gres.conf ]; then
        rm -f /etc/slurm/gres.conf
        echo "⚠️ 未检测到 GPU，已删除 gres.conf"
    else
        echo "ℹ️ 未检测到 GPU，无需生成 gres.conf"
    fi
fi



cat > /etc/slurm/cgroup.conf << 'EOF'
CgroupPlugin=disabled
EOF

# 从 cgroup v2 获取 CPU 和内存 Limit，生成启动命令
# ============================================
# 获取 CPU Limit
# ============================================
if [ -f "/sys/fs/cgroup/cpu.max" ]; then
    QUOTA=$(awk '{print $1}' /sys/fs/cgroup/cpu.max)
    PERIOD=$(awk '{print $2}' /sys/fs/cgroup/cpu.max)
    
    if [ "$QUOTA" != "max" ] && [ -n "$PERIOD" ] && [ "$PERIOD" -gt 0 ]; then
        CPUS=$((QUOTA / PERIOD))
        [ "$CPUS" -lt 1 ] && CPUS=1
    else
        CPUS=$(nproc)
    fi
else
    CPUS=$(nproc)
fi

# ============================================
# 获取 Memory Limit
# ============================================
if [ -f "/sys/fs/cgroup/memory.max" ]; then
    MEM_MAX=$(cat /sys/fs/cgroup/memory.max)
    if [ "$MEM_MAX" != "max" ]; then
        REAL_MEMORY=$((MEM_MAX / 1024 / 1024))
    else
        REAL_MEMORY=$(free -m | awk '/^Mem:/{print $2}')
    fi
else
    REAL_MEMORY=$(free -m | awk '/^Mem:/{print $2}')
fi

# ============================================
# 检测 GPU
# ============================================
GPU_CONF=""
if command -v nvidia-smi &> /dev/null && nvidia-smi -L &> /dev/null; then
    GPU_COUNT=$(nvidia-smi -L | wc -l)
    if [ "$GPU_COUNT" -gt 0 ]; then
        GPU_CONF=" Gres=gpu:${GPU_COUNT} Feature=gpu"
    else
        GPU_CONF=" Feature=cpu"
    fi
fi

# ============================================
# 输出启动命令（只 echo，不执行）
# ============================================
START_CMD="slurmd -Z --conf \"CPUs=${CPUS} RealMemory=${REAL_MEMORY}${GPU_CONF}\""
echo "$START_CMD"
eval "$START_CMD"