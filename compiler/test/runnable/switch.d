/*
RUN_OUTPUT:
---
A: yes
B: yes
C: yes
---
*/

// main.d -------------------------------------------------------

import core.stdc.stdio: printf;

void simple()
{
    enum K = 42;
    switch (K)
    {
        case 0 => printf("A: no0\n");
        case 42 => printf("A: yes\n");
        case 1 => printf("A: no1\n");

        default => printf("A: default\n");
    }
    switch (K)
    {
        case 0 => {
            printf("B: no0\n");
        }
        case 42 => {
            printf("B: yes\n");
        }
        case 1 => {
            printf("B: no1\n");
        }

        default => {
            printf("B: default\n");
        }
    }
    switch (K)
    {
        case 0: printf("C: no0\n"); break;
        case 42: printf("C: yes\n"); break;
        case 1: printf("C: no1\n"); break;

        default: printf("C: default\n");
    }
}


void send_1(short* to, short* from, int count)
{
    auto n = (count + 7) / 8;
    switch (count % 8) {
    case 0: do { *to++ = *from++;
                 goto case;
    case 7:      *to++ = *from++;
                 goto case;
    case 6:      *to++ = *from++;
                 goto case;
    case 5:      *to++ = *from++;
                 goto case;
    case 4:      *to++ = *from++;
                 goto case;
    case 3:      *to++ = *from++;
                 goto case;
    case 2:      *to++ = *from++;
                 goto case;
    case 1:      *to++ = *from++;
                 continue;
            } while (--n > 0);
            break;
    default: break;
    }
}

void send_2(short* to, short* from, int count)
{
    auto n = (count + 7) / 8;
    switch (count % 8) {
    case 0 => do { *to++ = *from++;
                 goto case;
    case 7 =>      *to++ = *from++;
                 goto case;
    case 6 =>      *to++ = *from++;
                 goto case;
    case 5 =>      *to++ = *from++;
                 goto case;
    case 4 =>      *to++ = *from++;
                 goto case;
    case 3 =>      *to++ = *from++;
                 goto case;
    case 2 =>      *to++ = *from++;
                 goto case;
    case 1 =>      *to++ = *from++;
                 continue;
            } while (--n > 0);
            break;
    default: break;
    }
}

void duff_device()
{
    {
        short[4] data = [1,2,3,4];
        short[4] output = 0;
        send_1(output.ptr, data.ptr, cast(int) data.length);
        assert(output[0] == 1 && output[1] == 2 && output[2] == 3 && output[3] == 4);
    }
    {
        short[4] data = [1,2,3,4];
        short[4] output = 0;
        send_2(output.ptr, data.ptr, cast(int) data.length);
        assert(output[0] == 1 && output[1] == 2 && output[2] == 3 && output[3] == 4);
    }
}

void main()
{
    simple();
    duff_device();
}
