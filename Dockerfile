################################################################
FROM ubuntu:latest AS base


# Setup environment variables in a single layer
ENV \
    # Prevent dpkg from prompting for user input during package setup
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    # mupen64plus will be installed in /usr/games; add to the $PATH
    PATH=$PATH:/usr/games \
    # Set default DISPLAY
    DISPLAY=:0


################################################################
FROM base AS buildstuff

RUN apt-get update && \
    apt-get install -y \
        build-essential libz-dev libpng-dev libsdl2-dev libfreetype-dev nasm libboost-dev libboost-filesystem-dev libjson-c4 libjson-c-dev \
        git

# clone, build, and install the input bot
# (explicitly specifying commit hash to attempt to guarantee behavior within this container)
WORKDIR /src/mupen64plus-src
RUN git clone https://github.com/mupen64plus/mupen64plus-core && \
        cd mupen64plus-core && \
        git reset --hard 12d136dd9a54e8b895026a104db7c076609d11ff && \
    cd .. && \
    git clone https://github.com/kevinhughes27/mupen64plus-input-bot && \
        cd mupen64plus-input-bot && \
        git reset --hard 0a1432035e2884576671ef9777a2047dc6c717a2 && \
    make all && \
    make install


################################################################
FROM base


# Update package cache and install dependencies
RUN apt-get update && \
    apt-get install -y \
        wget \
        git \
        xvfb libxv1 x11vnc \
        imagemagick \
        mupen64plus-ui-console \
        mupen64plus-data \
        nano \
        ffmpeg \
        libjson-c4 \
        software-properties-common

# Install Miniconda
RUN wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda.sh && \
    /bin/bash ~/miniconda.sh -b -p /opt/conda && \
    rm ~/miniconda.sh && \
    /opt/conda/bin/conda clean -tipsy && \
    ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo ". /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate base" >> ~/.bashrc

# Set path to conda
ENV PATH /opt/conda/bin:$PATH

# Updating Anaconda packages
RUN conda update conda -y
RUN conda update --all -y

# Install VirtualGL (provides vglrun to allow us to run the emulator in XVFB)
# (Check for new releases here: https://github.com/VirtualGL/virtualgl/releases)
ENV VIRTUALGL_VERSION=2.5.2
RUN wget "https://sourceforge.net/projects/virtualgl/files/${VIRTUALGL_VERSION}/virtualgl_${VIRTUALGL_VERSION}_amd64.deb" && \
    apt install ./virtualgl_${VIRTUALGL_VERSION}_amd64.deb && \
    rm virtualgl_${VIRTUALGL_VERSION}_amd64.deb

# Install Cuda
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/cuda-ubuntu2004.pin && \
    mv cuda-ubuntu2004.pin /etc/apt/preferences.d/cuda-repository-pin-600 && \
    apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/7fa2af80.pub && \
    add-apt-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/ /" && \
    apt-get update && \
    apt-get -y install cuda

# Install Cudnn
ENV OS=ubuntu2004
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/${OS}/x86_64/cuda-${OS}.pin && \
    mv cuda-${OS}.pin /etc/apt/preferences.d/cuda-repository-pin-600 && \
    apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/${OS}/x86_64/7fa2af80.pub && \
    add-apt-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/${OS}/x86_64/ /" && \
    apt-get update

ENV CUDNN_VERSION=8.1.1.*
ENV CUDA_VERSION=cuda11.2
RUN apt-get -y install libcudnn8=${CUDNN_VERSION}-1+${CUDA_VERSION} && \
    apt-get -y install libcudnn8-dev=${CUDNN_VERSION}-1+${CUDA_VERSION}

RUN conda install astunparse numpy ninja pyyaml mkl mkl-include setuptools cmake cffi typing_extensions future six requests dataclasses
RUN conda install -c pytorch magma-cuda112

# Build PyTorch From Source
RUN git clone --recursive https://github.com/pytorch/pytorch && \
    cd pytorch && \
    export CMAKE_PREFIX_PATH=${CONDA_PREFIX:-"$(dirname $(which conda))/../"} && \
    export TORCH_CUDA_ARCH_LIST=3.5+PTX && \
    export USE_CUDA=1 && \
    python setup.py install && \
    cd .. && \
    rm -r pytorch

RUN git clone --recursive https://github.com/pytorch/vision.git && \
    cd vision && \
    export FORCE_CUDA=1 && \
    export TORCH_CUDA_ARCH_LIST=3.5+PTX && \
    python setup.py install && \
    cd .. && \
    rm -r vision

# Install dependencies (here for caching)
RUN pip install --upgrade pip
RUN pip install \
    gym \
    numpy \
    PyYAML \
    termcolor \
    mss \
    opencv-python

# Copy compiled input plugin from buildstuff layer
COPY --from=buildstuff /usr/local/lib/mupen64plus/mupen64plus-input-bot.so /usr/local/lib/mupen64plus/

# Copy the gym environment (current directory)
COPY . /src/gym-mupen64plus
# Copy the Super Smash Bros. save file to the mupen64plus save directory
# mupen64plus expects a specific filename, hence the awkward syntax and name
COPY [ "./gym_mupen64plus/envs/Smash/smash.sra", "/root/.local/share/mupen64plus/save/Super Smash Bros. (U) [!].sra" ]

# Install requirements & this package
WORKDIR /src/gym-mupen64plus
RUN pip install -e .

# Declare ROMs as a volume for mounting a host path outside the container
VOLUME /src/gym-mupen64plus/gym_mupen64plus/ROMs/

WORKDIR /src

# Expose the default VNC port for connecting with a client/viewer outside the container
EXPOSE 5900
