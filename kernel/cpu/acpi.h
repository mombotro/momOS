#pragma once
#include <stdint.h>

/* Initialise ACPI: scan for RSDP, parse FADT, find PM1 control port and
   SLP_TYP values from the DSDT _S5_ package.  Call after paging_init(). */
void acpi_init(void);

/* Power off via ACPI S5 (soft off).  Does not return on success.
   Falls back to QEMU/Bochs port if ACPI tables not found. */
void acpi_shutdown(void);

/* Warm reboot via keyboard controller reset line.  Does not return. */
void acpi_reboot(void);
