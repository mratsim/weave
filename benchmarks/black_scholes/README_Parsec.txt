Name:  Black Scholes

Description: The Black-Scholes equation is a differential equation that
describes how, under a certain set of assumptions, the value of an option
changes as the price of the underlying asset changes.

The formula for a put option is similar. The cumulative normal distribution 
function, CND(x), gives the probability that normally distributed random
variable will have a value less than x. There is no closed form expression for
this function, and as such it must be evaluated numerically. Alternatively,
the values of this function may be pre-computed and hard-coded in the table; in
this case, they can be obtained at runtime using table lookup. We compare both
of these approaches in our work. The other parameters are as follows:
S underlying asset.s current price, X the strike price, T time to the
expiration date, r risk-less rate of return, and v stock.s volatility.

Based on this formula, one can compute the option price analytically based on
the five input parameters.  Using this analytical approach to price option,
the limiting factor lies with the amount of floating-point calculation a
processor can perform.

Parallelization: Our parallelization algorithms is very simple: we simply price 
multiple options in parallel using Black-Scholes formula. Each thread prices an 
individual option. In practice financial houses price 10.s to 100.s of thousandsof options using Black-Scholes.

=======================================
Programming Languages & Libraries:

C/C++ and Pthread is used to implement this benchmark.

=======================================
System requirements:

 1) Intel(R) C++ Compiler: version 9.0 or higher
 2) GNU gcc/g++: version 3.3 or higher
 3) sed: version 4.0.9 or higher recommended.
The minimum required memory size is 140 MBytes.
=======================================
Input/Output:
The input data file of this benchmark includes an array of data of 
options.

The output benchmark will output the price of the options based on the five
input parameters in the dataset file. 


=======================================
Characteristics:

(1) Hotspot
Hotspot of the benchmark includes computing the price of options using 
black scholes formula and  the cumulative normal distribution function.
They are implemented in BlkSchlsEqEuroNoDiv and CNDF in "bs.c" respectly.

=======================================
Revision History

Date: Person-making-revision  brief-description-of-revision

=======================================
Author: Victor Lee, Mikhail Smelyanskiy

Acknowledgements:

References:
[Black73] Black, Fischer, and M. Scholes. The Pricing of Options and Corporate Liabilities. Journal of Political Economy, 81:637--659, May--June 1973.

