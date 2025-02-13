int f(int x, int y) @ctonly {
    return x + y;
}

int g(int x)(int y) @ctonly {
    return x + y;
}

alias gf = g!2;

/* enums are fine */
enum e = g!4(2);
/* globals initializers are fine */
int z = f(2, 5);

void main() {
    /* enums are fine */
    enum x = f(2, 4);
    enum y = gf(4);
    /* static asserts are fine */
    static assert (f(2, 2) == g!4(0));
    /* array indeces are fine */
    int[g!10(0)] arr;
}
