// The compact runtime deliberately has no .init_array walker. This object is
// linked only by the negative policy test and must be rejected by the script.
struct constructor_probe
{
    constructor_probe();
    int value;
};

volatile int constructor_source = 7;

constructor_probe::constructor_probe() : value(constructor_source) {}

constructor_probe global_constructor_probe;
