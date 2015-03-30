FROM phusion/baseimage
MAINTAINER Phillip Wittrock < philwittrock [at] gmail {dot} com>

# Additional Repose
RUN add-apt-repository ppa:webupd8team/java
RUN apt-get update
RUN apt-get upgrade -y

RUN apt-get install -y mongodb

RUN apt-get install -y git

RUN apt-get install -y npm
RUN ln -s /usr/bin/nodejs /usr/bin/node

RUN apt-get install -y python-software-properties software-properties-common
RUN apt-get install -y unzip
RUN apt-get install -y wget

# Java
RUN echo debconf shared/accepted-oracle-license-v1-1 select true | debconf-set-selections
RUN echo debconf shared/accepted-oracle-license-v1-1 seen true | debconf-set-selections
RUN apt-get install -y oracle-java8-installer oracle-java8-set-default
ENV JAVA_HOME /usr/lib/jvm/java-8-oracle

# Node
RUN npm install -g bower
RUN npm install -g coffee-script

ENV LEIN_ROOT true
RUN wget -q -O /usr/bin/lein \
  https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein \
  && chmod +x /usr/bin/lein \
  && /usr/bin/lein

RUN curl -s https://storage.googleapis.com/signals-agents/logging/install-google-fluentd-debian-wheezy.sh | sh

# Setup user account
RUN useradd -ms /bin/bash jinteki
USER jinteki
ENV HOME /home/jinteki
WORKDIR $HOME

RUN lein

USER root
RUN apt-get install libzmq3-dev -y
ADD package.json $HOME/package.json
RUN chown -R jinteki:jinteki $HOME/

USER jinteki
RUN npm install
ADD project.clj $HOME/project.clj
ADD profiles.clj $HOME/profiles.clj
ADD bower.json $HOME/bower.json
RUN echo "yes" | bower install
RUN npm install zmq
RUN lein cljsbuild once

USER root
ADD * $HOME/
RUN chown -R jinteki:jinteki $HOME/
USER jinteki

# Install src from local build
WORKDIR $HOME/
RUN lein cljsbuild once
RUN lein uberjar

USER root
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

EXPOSE 1042
EXPOSE 1043
