#!/bin/sh
# fastd ruft das je Geraet beim Anlegen seines tap-Interfaces auf.
ip link set "$INTERFACE" master br-otm
bridge link set dev "$INTERFACE" isolated on
ip link set "$INTERFACE" up
