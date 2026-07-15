BUILD_DIR := build

.PHONY: build test clean

build:
	cmake -B $(BUILD_DIR) && cmake --build $(BUILD_DIR)

test: build
	ctest --test-dir $(BUILD_DIR) --output-on-failure

clean:
	rm -rf $(BUILD_DIR) bin
