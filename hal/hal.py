#!/usr/bin/env python

import hal

h = hal.component("circle")
h.newpin("center", hal.HAL_FLOAT, hal.HAL_IN)
h.newpin("radius", hal.HAL_FLOAT, hal.HAL_IN)
h.ready()
