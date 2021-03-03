from setuptools import Extension, setup
from Cython.Build import cythonize

setup(
    ext_modules = cythonize("unthrow/*.pyx",build_dir="build")
)
