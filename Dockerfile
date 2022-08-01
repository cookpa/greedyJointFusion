FROM ubuntu:focal as builder

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
         apt-get install -y --no-install-recommends \
             apt-transport-https \
             build-essential \
             ca-certificates \
             cmake \
             gnupg \
             ninja-build \
             git \
             software-properties-common \
             wget \
             zlib1g-dev

RUN mkdir /opt/src /opt/bin \
    && cd /opt/src \
    && git clone -b v5.1.2 --depth 1 https://github.com/InsightSoftwareConsortium/ITK.git \
    && git clone -b v9.1.0 --depth 1 https://github.com/Kitware/VTK.git \
    && git clone https://github.com/pyushkevich/c3d.git \
    && git clone https://github.com/pyushkevich/ashs.git \
    && git clone https://github.com/pyushkevich/greedy

# Build ITK
RUN mkdir -p /opt/build/ITK \
    && cd /opt/build/ITK \
    && cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING:BOOL=OFF \
       -DModule_ITKDeprecated:BOOL=ON -DModule_ITKReview:BOOL=ON \
       -DModule_MorphologicalContourInterpolation:BOOL=ON \
       /opt/src/ITK \
    && make -j 2
# Build VTK
RUN mkdir -p /opt/build/VTK \
    && cd /opt/build/VTK \
    && cmake -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING:BOOL=OFF \
       -DCMAKE_BUILD_TYPE:STR="Release" ../../src/VTK \
    && make -j 2
# Build c3d
# Not strictly needed but might be useful later
RUN mkdir -p /opt/build/c3d \
    && cd /opt/build/c3d \
    && cmake -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING:BOOL=OFF \
      -DITK_DIR:STRING=/opt/build/ITK ../../src/c3d \
    && make -j 2
# Build greedy
RUN mkdir -p /opt/build/greedy \
    && cd /opt/build/greedy \
    && cmake -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING:BOOL=OFF -DITK_DIR:STRING=/opt/build/ITK \
       -DVTK_DIR:STRING=/opt/build/VTK ../../src/greedy \
    && make -j 2
# Build label_fusion
RUN cd /opt/src/ashs \
    && git checkout -b fastashs \
    && mkdir -p /opt/build/LabelFusion \
    && cd /opt/build/LabelFusion \
    && cmake -DBUILD_SHARED_LIBS:BOOL=OFF -DITK_DIR:STRING=/opt/build/ITK -DCMAKE_BUILD_TYPE=Release \
       ../../src/ashs/src/LabelFusion \
    && make -j 2


FROM ubuntu:focal

COPY greedyJointLabelFusion.pl /opt/bin

COPY --from=builder /opt/build/c3d/c*d \
     /opt/build/c3d/c3d_affine_tool \
     /opt/build/greedy/greedy \
     /opt/build/greedy/greedy_template_average \
     /opt/build/greedy/multi_chunk_greedy \
     /opt/build/LabelFusion/label_fusion \
     /opt/bin

ENV "PATH=/opt/bin:$PATH"

RUN chmod a+x /opt/bin/*

ENTRYPOINT /opt/bin/greedyJointLabelFusion.pl
