#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <curand_kernel.h>

#include <thrust/sort.h>
#include <thrust/partition.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include<thrust/scan.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1
#define RANDVEC3 glm::vec3(curand_uniform(local_rand_state),curand_uniform(local_rand_state),curand_uniform(local_rand_state))


#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

__device__ inline bool isNAN(const glm::vec3& v)
{
	return (v.x != v.x) || (v.y != v.y) || (v.z != v.z);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

class CUDATimer
{
public:
	CUDATimer(const std::string& inName)
	{
		name = inName;

		cudaEventCreate(&startEvent);
		cudaEventCreate(&stopEvent);
	}

	~CUDATimer()
	{
		cudaEventDestroy(startEvent);
		cudaEventDestroy(stopEvent);
	}

	void start()
	{
		cudaEventRecord(startEvent);
	}

	void stop()
	{
		cudaEventRecord(stopEvent);

		cudaEventSynchronize(stopEvent);

		float milliseconds = 0;
		cudaEventElapsedTime(&milliseconds, startEvent, stopEvent);

		printf("%sIt takes: %f ms\n", name.c_str(), milliseconds);
	}

private:
	cudaEvent_t startEvent;
	cudaEvent_t stopEvent;
	std::string name;
};

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static int* dev_materialSortBuffer = nullptr;
static int* dev_materialSortBuffer2 = nullptr;
static ShadeableIntersection* dev_intersections = NULL;

int samplesPerPixel = 1;

bool sortMaterial = false;

int* dev_perm_x = nullptr;
int* dev_perm_y = nullptr;
int* dev_perm_z = nullptr;

perlin** dev_perlinNoise = nullptr;

bool perlinInitialized = false;

// static variables for device memory, any extra info you need, etc
static ShadeableIntersection* dev_cache = NULL;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

__global__ void initPerlin(perlin** perlinNoise, thrust::default_random_engine rng, int* dev_perm_x, int* dev_perm_y, int* dev_perm_z)
{
	*perlinNoise = new perlin(rng, dev_perm_x, dev_perm_y, dev_perm_z);
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	samplesPerPixel = guiData->SamplePerPixel;

	//hst_scene->state.traceDepth = guiData->Depth;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, samplesPerPixel * pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_materialSortBuffer, samplesPerPixel * pixelcount * sizeof(int));
	cudaMalloc(&dev_materialSortBuffer2, samplesPerPixel * pixelcount * sizeof(int));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, samplesPerPixel * pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, samplesPerPixel * pixelcount * sizeof(ShadeableIntersection));

	// initialize any extra device memeory you need
	cudaMalloc(&dev_cache, samplesPerPixel * pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_cache, 0, samplesPerPixel * pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_perm_x, 256 * sizeof(int));
	cudaMemset(dev_perm_x, 0, 256 * sizeof(int));

	cudaMalloc(&dev_perm_y, 256 * sizeof(int));
	cudaMemset(dev_perm_y, 0, 256 * sizeof(int));

	cudaMalloc(&dev_perm_z, 256 * sizeof(int));
	cudaMemset(dev_perm_z, 0, 256 * sizeof(int));

	cudaMalloc(&dev_perlinNoise, sizeof(perlin*));

	thrust::default_random_engine rng = makeSeededRandomEngine(0, 1, 2);

	initPerlin<<<1, 1>>>(dev_perlinNoise, rng, dev_perm_x, dev_perm_y, dev_perm_z);

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_materialSortBuffer);
	cudaFree(dev_materialSortBuffer2);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	// TODO: clean up any extra device memory you created
	cudaFree(dev_cache);
	checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments, int samplesPerPixel)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);


		// implement antialiasing by jittering the ray
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, traceDepth);
		thrust::uniform_real_distribution<float> u01(0, 1);

		for (int i = 0; i < samplesPerPixel; i++)
		{
			int jitterIndex = cam.resolution.x * cam.resolution.y * i + index;

			PathSegment& segment = pathSegments[jitterIndex];

			segment.ray.origin = cam.position;
			segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

			glm::vec2 jitter = glm::vec2(0.5f * (u01(rng) * 2.0f - 1.0f), 0.5f * (u01(rng) * 2.0f - 1.0f));

			if (i == 0)
			{
				jitter = glm::vec2(0.0f);
			}

			pathSegments[jitterIndex].ray.direction = glm::normalize(cam.view
				- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f + jitter[0])
				- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f + jitter[1]));

			segment.pixelIndex = index;
			segment.remainingBounces = traceDepth;
		}
	}
}


__global__ void computeIntersections(
	int depth
	, int maxDepth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, int geoms_size
	, ShadeableIntersection* intersections
	, glm::vec3* image
	, cudaTextureObject_t skyboxTex
	, int imageWidth
	, int imageHeight
	, int samplesPerPixel
	, int* materialKeys
)
{
	int pathIndex = blockIdx.x * blockDim.x + threadIdx.x;

	if (pathIndex >= num_paths)
	{
		return;
	}

	for (int i = 0; i < samplesPerPixel; i++)
	{
		int jitterIndex = imageWidth * imageHeight * i + pathIndex;

		PathSegment& pathSegment = pathSegments[jitterIndex];

		intersections[jitterIndex].materialId = -1;

		float t;
		glm::vec3 intersectPoint;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;
		float u;
		float v;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside, u, v);
			}
			else if (geom.type == MESH)
			{
				t = triangleIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == PROCEDURAL)
			{
				t = proceduralIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}

			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersectPoint = tmp_intersect;
				normal = tmp_normal;
			}
		}

		int materialId = -1;
		if (hit_geom_index == -1)
		{
			intersections[jitterIndex].t = -1.0f;

			if (pathSegment.remainingBounces == maxDepth)
			{
				pathSegment.needSkyboxColor = true;
			}

			pathSegment.remainingBounces = 0;
		}
		else
		{
			//The ray hits something
			intersections[jitterIndex].t = t_min;
			intersections[jitterIndex].materialId = geoms[hit_geom_index].materialid;
			intersections[jitterIndex].surfaceNormal = normal;
			intersections[jitterIndex].frontFace = outside;
			intersections[jitterIndex].point = intersectPoint;
			intersections[jitterIndex].u = u;
			intersections[jitterIndex].v = v;
			materialId = intersections[jitterIndex].materialId;
		}
		materialKeys[jitterIndex] = materialId;
	}
}

__global__ void shadeFakeMaterial(
	int iter
	, int numPaths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
	, int imageWidth
	, int imageHeight
	, int samplesPerPixel
	, perlin** perlinNoise
	, int* dev_perm_x
	, int* dev_perm_y
	, int* dev_perm_z
	, cudaTextureObject_t skyBoxTexture
)
{
	int pathIndex = blockIdx.x * blockDim.x + threadIdx.x;

	if (pathIndex >= numPaths)
	{
		return;
	}

	// Set up the RNG
	// LOOK: this is how you use thrust's RNG! Please look at
	// makeSeededRandomEngine as well.
	thrust::default_random_engine rng = makeSeededRandomEngine(iter, pathIndex, 0);
	thrust::uniform_real_distribution<float> u01(0, 1);

	// getPointOnRay(pathSegments[idx].ray, intersection.t)

	glm::vec3 color = glm::vec3(0.0f);

	for (int i = 0; i < samplesPerPixel; i++)
	{
		int jitterIndex = imageWidth * imageHeight * i + pathIndex;

		if (pathSegments[jitterIndex].remainingBounces == 0)
		{

			glm::vec2 uv = sampleHDRMap(glm::normalize(pathSegments[jitterIndex].ray.direction));
			float4 skyColorRGBA = tex2D<float4>(skyBoxTexture, uv.x, uv.y);
			glm::vec3 skyColor = glm::vec3(skyColorRGBA.x, skyColorRGBA.y, skyColorRGBA.z);

			color += pathSegments[jitterIndex].color;

			continue;
		}

		ShadeableIntersection intersection = shadeableIntersections[jitterIndex];

		Material material;

		if (intersection.materialId >= 0)
		{
			material = materials[intersection.materialId];
		}

		scatterRay(pathSegments[jitterIndex], intersection, intersection.point, intersection.surfaceNormal, intersection.frontFace, material, rng);

		if (material.pattern == Pattern::PerlinNoise)
		{
			glm::vec3 perlinNoiseColor = glm::vec3(1.0f, 1.0f, 1.0f) * 0.5f *
				(1.0f + glm::sin(1.0f * intersection.point.z + 10.0f *
					(*perlinNoise)->turb(intersection.point, 7, dev_perm_x, dev_perm_y, dev_perm_z)));


			glm::vec3 darkGreen = glm::vec3(0.09f, 0.45f, 0.08f);
			glm::vec3 lightGreen = glm::vec3(0.61f, 0.82f, 0.49f);

			glm::vec3 grassColor = glm::mix(darkGreen, lightGreen, perlinNoiseColor.x); 

			pathSegments[jitterIndex].color *= grassColor;
		}


		color += pathSegments[jitterIndex].color;
	}

	color /= samplesPerPixel;

	pathSegments[pathIndex].color = color;
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int numPaths, glm::vec3* image, PathSegment* iterationPaths, cudaTextureObject_t skyboxTexture)
{
	int pathIndex = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (pathIndex < numPaths)
	{
		PathSegment iterationPath = iterationPaths[pathIndex];
		if (!isNAN(iterationPath.color))
		{
			glm::vec2 uv = sampleHDRMap(glm::normalize(iterationPath.ray.direction));
			float4 skyColorRGBA = tex2D<float4>(skyboxTexture, uv.x, uv.y);
			glm::vec3 skyColor = glm::vec3(skyColorRGBA.x, skyColorRGBA.y, skyColorRGBA.z);

			if (iterationPath.needSkyboxColor)
			{
				image[iterationPath.pixelIndex] += iterationPath.color * skyColor * 3.0f;
			}
			else
			{
				image[iterationPath.pixelIndex] += iterationPath.color;
			}
		}
	}
}

__global__ void computeReflectionForWaterPattern(
	int num_paths,
	PathSegment* dev_paths,
	ShadeableIntersection* dev_intersections,
	Material* dev_materials
) {
	int pathIndex = blockIdx.x * blockDim.x + threadIdx.x;

	if (pathIndex >= num_paths) return;

	ShadeableIntersection intersection = dev_intersections[pathIndex];
	if (intersection.t > 0.0f) {  // if there is an intersection
		Material material = dev_materials[intersection.materialId];
		if (material.pattern == Pattern::PerlinNoise) {
			glm::vec3 incidentDir = -dev_paths[pathIndex].ray.direction;
			glm::vec3 reflectDir = glm::reflect(incidentDir, intersection.surfaceNormal);

			// Update the path segment with the new direction
			dev_paths[pathIndex].ray.direction = reflectDir;
		}
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths, samplesPerPixel);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;
	int current_num_paths = num_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;

	while (!iterationComplete) {
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;

		if (depth == 0)
		{
			if (iter == 1) {
				// tracing
				computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
					depth
					, traceDepth
					, num_paths
					, dev_paths
					, dev_geoms
					, hst_scene->geoms.size()
					, dev_intersections
					, dev_image
					, hst_scene->skyboxTextureObject
					, cam.resolution.x
					, cam.resolution.y
					, samplesPerPixel
					, dev_materialSortBuffer
					);
				checkCUDAError("trace one bounce");
				cudaDeviceSynchronize();
				cudaMemcpy(dev_cache, dev_intersections, samplesPerPixel * pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			}
			else {
				cudaMemcpy(dev_intersections, dev_cache, samplesPerPixel * pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			}

		}
		else {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, traceDepth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				, dev_image
				, hst_scene->skyboxTextureObject
				, cam.resolution.x
				, cam.resolution.y
				, samplesPerPixel
				, dev_materialSortBuffer
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
		}
		depth++;


		shadeFakeMaterial << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			cam.resolution.x,
			cam.resolution.y,
			samplesPerPixel,
			dev_perlinNoise,
			dev_perm_x,
			dev_perm_y,
			dev_perm_z,
			hst_scene->skyboxTextureObject
			);

		//CUDATimer timer("shadeFakeMaterial");

		//timer.start();

		if (sortMaterial)
		{
			cudaMemcpy(dev_materialSortBuffer2, dev_materialSortBuffer, sizeof(int) * num_paths, cudaMemcpyDeviceToDevice);
			thrust::sort_by_key(thrust::device, dev_materialSortBuffer, dev_materialSortBuffer + num_paths, dev_intersections);
			thrust::sort_by_key(thrust::device, dev_materialSortBuffer2, dev_materialSortBuffer2 + num_paths, dev_paths);

			//timer.stop();

			dev_path_end = thrust::partition(thrust::device, dev_paths, dev_path_end, returnRemainBounce());
			current_num_paths = dev_path_end - dev_paths;

			//printf("%d\n", current_num_paths);

			iterationComplete = (depth >= traceDepth || current_num_paths <= 0);
		}
		else
		{
			if (depth == traceDepth)
			{
				iterationComplete = true; 
			}
		}

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;

			samplesPerPixel = guiData->SamplePerPixel;
		}
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths, hst_scene->skyboxTextureObject);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
