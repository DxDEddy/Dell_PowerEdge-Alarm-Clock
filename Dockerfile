FROM ubuntu:latest

LABEL org.opencontainers.image.authors="DxDEddy"

RUN apt-get update

RUN apt-get install ipmitool iputils-ping -y

ADD functions.sh /app/functions.sh
ADD constants.sh /app/constants.sh
ADD healthcheck.sh /app/healthcheck.sh
ADD Dell_iDRAC_fan_controller.sh /app/Dell_iDRAC_fan_controller.sh

RUN chmod 0777 /app/functions.sh /app/healthcheck.sh /app/Dell_iDRAC_fan_controller.sh

WORKDIR /app

HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 CMD [ "/app/healthcheck.sh" ]

# you should override these default values when running. See README.md
# ENV IDRAC_HOST=192.168.1.100
ENV IDRAC_HOST=local
# ENV IDRAC_USERNAME=root
# ENV IDRAC_PASSWORD=calvin
ENV FAN_SPEED=5
ENV CPU_TEMPERATURE_THRESHOLD=50
ENV CHECK_INTERVAL=60
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
ENV KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false

# Alarm clock feature - ramp fans to wake you up
# Shared defaults inherited by all numbered alarms (ALARM_1_*, ALARM_2_*, etc.)
ENV ALARM_ENABLED=false
ENV ALARM_CHECK_HOSTS=workpc.local
ENV ALARM_HOST_LOGIC=any
ENV ALARM_FAN_SPEED=100
ENV ALARM_PERSIST=false
ENV ALARM_MAX_DURATION=60

ENV TZ=Europe/London

ENTRYPOINT ["./Dell_iDRAC_fan_controller.sh"]
