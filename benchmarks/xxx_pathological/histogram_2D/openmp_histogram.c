// Source: https://stackoverflow.com/questions/16751445/parallelize-nested-for-loop-with-openmp

#include<stdio.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#define float_t float
#include <time.h>
#include <omp.h>

// This was the original function to optimize
// where the reader had issues with OpenMP nested parallelism
float_t generate_histogram(float_t **matrix, int *histogram, int mat_size, int hist_size)
{
int i,j,k,count;
float_t max = 0.;
float_t sum;

//set histogram to zero everywhere
for(i = 0; i < hist_size; i++)
    histogram[i] = 0;


//matrix computations
//#pragma omp parallel for schedule(runtime)
for (i = 1; i < (mat_size-1); i++)
{
    //pragma omp prallel for schedule(dynamic)
    for(j = 1; j < (mat_size-1); j++)
    {

        //assign current matrix[i][j] to element in order to reduce memory access
        sum = fabs(matrix[i][j]-matrix[i-1][j]) + fabs(matrix[i][j] - matrix[i+1][j])
            + fabs(matrix[i][j]-matrix[i][j-1]) + fabs(matrix[i][j] - matrix[i][j+1]);

        //compute index of histogram bin
        k = (int)(sum * (float)mat_size);
        histogram[k] += 1;

        //keep track of largest element
        if(sum > max)
            max = sum;

    }//end inner for
}//end outer for

return max;
}

// This is the proposed alaternative
float_t generate_histogram_omp(float_t **matrix, int *histogram, int mat_size, int hist_size) {
    float_t max = 0.;
    //set histogram to zero everywhere
    int i;
    for(i = 0; i < hist_size; i++)
        histogram[i] = 0;

    //matrix computations
    #pragma omp parallel
    {
        int *histogram_private = (int*)malloc(hist_size * sizeof(int));
        int i;
        for(i = 0; i < hist_size; i++)
            histogram_private[i] = 0;
        float_t max_private = 0.;
        int n;
        int j;
        #pragma omp for
        for (i = 1; i < (mat_size-1); i++) {
            for(j = 1; j < (mat_size-1); j++) {
         //   for (n=0; n < (mat_size-2)*(mat_size-2); n++) {
          //      int i = n/(mat_size-2)+1;
          //      int j = n%(mat_size-2)+1;

                float_t sum = fabs(matrix[i][j]-matrix[i-1][j]) + fabs(matrix[i][j] - matrix[i+1][j])
                    + fabs(matrix[i][j]-matrix[i][j-1]) + fabs(matrix[i][j] - matrix[i][j+1]);

                //compute index of histogram bin
                int k = (int)(sum * (float)mat_size);
                histogram_private[k] += 1;

                //keep track of largest element
                if(sum > max_private)
                    max_private = sum;
            }
        }
        #pragma omp critical
        {

            for(i = 0; i < hist_size; i++)
                histogram[i] += histogram_private[i];
            if(max_private>max)
                max = max_private;
        }

        free(histogram_private);
    }
    return max;
}

int compare_hists(int *hist1, int *hist2, int N) {
    int i;
    int diff = 0;
    for(i =0; i < N; i++) {
        int tmp = hist1[i] - hist2[i];
        diff += tmp;
        if(tmp!=0) {
            printf("i %d, hist1 %d, hist2  %d\n", i, hist1[i], hist2[i]);
        }
    }
    return diff;
}

int main() {
    int i,j,N,boxes;

    // Original values
    // N = 10000;
    // boxes = N / 2;

    N = 25000;
    boxes = 1000;

    float_t **matrix;
    int* histogram1;
    int* histogram2;

    //allocate a matrix with some numbers
    matrix = (float_t**)calloc(N, sizeof(float_t **));
    for(i = 0; i < N; i++)
        matrix[i] = (float_t*)calloc(N, sizeof(float_t *));
    for(i = 0; i < N; i++)
        for(j = 0; j < N; j++)
            matrix[i][j] = 1./(float_t) N * (float_t) i * 100.0;


    histogram1 = (int*)malloc(boxes * sizeof(int));
    histogram2 = (int*)malloc(boxes * sizeof(int));

    for(i = 0; i<boxes; i++) {
        histogram1[i] = 0;
        histogram2[i] = 0;
    }
    double dtime;

    // dtime = omp_get_wtime();
    // float_t max1 = generate_histogram(matrix, histogram1, N, boxes);
    // dtime = omp_get_wtime() - dtime;
    // printf("time serial: %f\n", dtime);
    // printf("max  serial: %f\n", max1);

    dtime = omp_get_wtime();
    float_t max2 = generate_histogram_omp(matrix, histogram2, N, boxes);
    dtime = omp_get_wtime() - dtime;
    printf("time openmp: %f\n", dtime);
    printf("max  openmp: %f\n", max2);

    int diff = compare_hists(histogram1, histogram2, boxes);
    printf("diff %d\n", diff);

    return 0;
}
