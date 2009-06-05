#define ULAPI

#include <hal.h>

int M;
hal_s32_t* Pins;

void RealtimeMain(void* arg, long period) {
  Pins[2] = Pins[0] + Pins[1];
}

int main(int argc, char* argv[]) {
  M = hal_init("haltest");
  Pins = (hal_s32_t*) hal_malloc(3*sizeof(hal_s32_t));
  hal_pin_s32_new("in0",HAL_IN,&Pins,M);
  hal_pin_s32_new("in1",HAL_IN,&Pins+1,M);
  hal_pin_s32_new("out",HAL_OUT,&Pins+2,M);
  hal_export_funct("haltest",RealtimeMain,NULL,0,1,M);
  hal_ready(M);
  return 0;
}
