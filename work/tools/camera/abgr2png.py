import sys, numpy as np
from PIL import Image
w,h,stride=1440,1080,5888
d=np.fromfile(sys.argv[1],dtype=np.uint8)[:h*stride].reshape(h,stride)
px=d[:,:w*4].reshape(h,w,4)  # A,B,G,R
rgb=np.dstack([px[:,:,3],px[:,:,2],px[:,:,1]]).astype(np.float32)
# autoscale to show any texture
p99=np.percentile(rgb,99.5) or 1
rgb=np.clip(rgb*(255.0/max(p99,1)),0,255)
Image.fromarray(rgb.astype(np.uint8)).save(sys.argv[2])
print("in mean",d[:,:w*4].reshape(h,w,4)[:,:,2].mean(),"p99.5",p99)
